import AppKit
import AVKit
import AVFoundation
import Carbon.HIToolbox

/// Player + trimmer for recordings Topkit just made. Not a general video
/// player: it only ever opens files produced by ScreenRecordingManager.
/// Trim uses AVPlayerView's built-in QuickTime trim UI; committing a trim
/// passthrough-exports the kept range and atomically overwrites the file.
/// Dragging the title bar (the file's name and icon) drags the recording
/// file into other apps.
final class RecordingPlayerWindowController: NSWindowController, NSWindowDelegate, NSDraggingSource {

    private var fileURL: URL
    private let playerView = AVPlayerView()
    private var trimButton: NSButton?
    private var renameButton: NSButton?
    private var deleteButton: NSButton?
    private var keyMonitor: Any?
    private var titleBarMonitor: Any?
    /// Sits over the file's name so the window server never starts a window
    /// move there: the press is a file drag, not a move.
    private let fileNameGrip = TitleBarGripView()
    private var titleFieldObserver: NSObjectProtocol?
    private var trimAccessory: NSView?
    /// A committed trim is being written over the file: no drag until done.
    private var isExportingTrim = false
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
        // Dragging the file's name or icon drags the recording into other apps
        // (see handleTitleBarPress); the rest of the title bar moves the window
        // as usual. The icon keeps its ⌘-click path menu.
        window.representedURL = fileURL
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

        // Delete (⌘⌫) discards the recording. Destructive, so it sits last.
        let delete = NSButton(title: String(localized: "Delete"), target: self, action: #selector(deleteTapped))
        delete.bezelStyle = .toolbar
        if let bin = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete") {
            delete.image = bin
            delete.imagePosition = .imageLeading
        }

        // One even gap between the three, and the same inset after the last.
        let gap: CGFloat = 4
        let buttons = [rename, trim, delete]
        var x: CGFloat = 0
        let container = NSView()
        for button in buttons {
            let width = ceil(button.fittingSize.width)
            button.frame = NSRect(x: x, y: 3, width: width, height: 22)
            container.addSubview(button)
            x += width + gap
        }
        container.frame = NSRect(x: 0, y: 0, width: x - gap + 8, height: 28)
        accessory.view = container
        accessory.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(accessory)
        trimAccessory = container
        trimButton = trim
        renameButton = rename
        deleteButton = delete

        // ⌘T (trim) / ⌘R (rename) / ⌘⌫ (delete) / ⌘W (close) while this window
        // is key — an accessory app has no main menu, so the standard Close
        // equivalent must be manual, same as the preferences window.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true,
                  event.modifierFlags.contains(.command) else { return event }
            if event.keyCode == UInt16(kVK_Delete) {
                self.deleteTapped()
                return nil
            }
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

        // Title bar presses are taken before AppKit's title bar sees them:
        // its own tracking loop would swallow the drag.
        titleBarMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  self.isTitleBarDragArea(event, in: window) else { return event }
            self.handleTitleBarPress(event, in: window)
            return nil
        }

        window.center()
        placeFileNameGrip()
    }

    /// Puts the grip over the file's name, wherever AppKit has laid the title
    /// out (it moves on resize, rename and full screen).
    private func placeFileNameGrip() {
        guard let window, let field = Self.titleField(in: window), let host = field.superview else {
            fileNameGrip.removeFromSuperview()
            return
        }
        if titleFieldObserver == nil {
            field.postsFrameChangedNotifications = true
            titleFieldObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: field, queue: .main
            ) { [weak self] _ in self?.placeFileNameGrip() }
        }
        if fileNameGrip.superview !== host {
            fileNameGrip.removeFromSuperview()
            host.addSubview(fileNameGrip, positioned: .above, relativeTo: field)
        }
        fileNameGrip.frame = host.convert(Self.fileNameRect(of: field), from: field)
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
        deleteButton?.isEnabled = false
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
        deleteButton?.isEnabled = true
        if let item = playerView.player?.currentItem {
            item.reversePlaybackEndTime = .invalid
            item.forwardPlaybackEndTime = .invalid
        }
    }

    private func exportTrimmed(range: CMTimeRange) {
        isExportingTrim = true
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
        isExportingTrim = false
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
        placeFileNameGrip()
        window?.representedURL = newURL
        ToastPresenter.shared.show(message: String(localized: "Recording renamed"))
    }

    // MARK: - Delete

    @objc private func deleteTapped() {
        // Not while a trim is open or exporting: the export still reads the
        // file and would write a temp file nobody cleans up.
        guard let window, window.attachedSheet == nil, deleteButton?.isEnabled == true else { return }
        let name = fileURL.lastPathComponent
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete Recording")
        switch RecordingDestination.discardMethod(for: fileURL) {
        case .moveToTrash:
            alert.informativeText = String(localized: "“\(name)” will be moved to the Trash.")
        case .removeTemporaryFile:
            alert.informativeText = String(localized: "“\(name)” will be deleted. This cannot be undone.")
        }
        // Same order as Clear Clipboard History: Cancel left, destructive right.
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.buttons.last?.hasDestructiveAction = true

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertSecondButtonReturn else { return }
            self.performDelete()
        }
    }

    private func performDelete() {
        // Release the file before it moves, mirroring rename/trim.
        playerView.player?.pause()
        playerView.player?.replaceCurrentItem(with: nil)

        guard let method = RecordingDestination.discardRecording(at: fileURL) else {
            playerView.player = AVPlayer(url: fileURL)
            ToastPresenter.shared.show(message: String(localized: "Delete failed"), force: true)
            return
        }
        ToastPresenter.shared.show(message: method == .moveToTrash
            ? String(localized: "Recording moved to Trash")
            : String(localized: "Recording deleted"))
        // windowWillClose drops the player, the key monitor and the folder scope.
        window?.close()
    }

    // MARK: - Drag to other apps

    /// The file's name in the title bar. The file icon next to it drags
    /// through AppKit (`window(_:shouldDragDocumentWith:…)`); everywhere else
    /// on the title bar moves the window. Not in full screen or under a sheet.
    private func isTitleBarDragArea(_ event: NSEvent, in window: NSWindow) -> Bool {
        isFileNameDragPoint(event.locationInWindow, in: window)
    }

    /// `point` is in window coordinates.
    func isFileNameDragPoint(_ point: NSPoint, in window: NSWindow) -> Bool {
        guard window.attachedSheet == nil,
              !window.styleMask.contains(.fullScreen),
              point.y >= window.contentLayoutRect.maxY,
              let field = Self.titleField(in: window) else { return false }
        return Self.fileNameRect(of: field).contains(field.convert(point, from: nil))
    }

    /// The name's text inside the title field (the field can be wider), in the
    /// field's coordinates, with a little slack each side.
    static func fileNameRect(of field: NSTextField) -> NSRect {
        let textWidth = ceil(field.attributedStringValue.size().width)
        let left: CGFloat
        switch field.alignment {
        case .center: left = (field.bounds.width - textWidth) / 2
        case .right: left = field.bounds.width - textWidth
        default: left = 0
        }
        return NSRect(x: left - 2, y: 0, width: textWidth + 4, height: field.bounds.height)
    }

    /// The text field AppKit draws the window title in.
    static func titleField(in window: NSWindow) -> NSTextField? {
        guard let frameView = window.contentView?.superview else { return nil }
        func find(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.stringValue == window.title, !field.isHidden { return field }
            for subview in view.subviews {
                if let found = find(subview) { return found }
            }
            return nil
        }
        return find(frameView)
    }

    /// Runs the press like Finder runs a file: a click does what a title bar
    /// click does, a drag past the threshold becomes a file drag, ⌘-drag
    /// moves the window.
    private func handleTitleBarPress(_ press: NSEvent, in window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let movesWindow = press.modifierFlags.contains(.command)
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if event.type == .leftMouseUp {
                if !movesWindow, press.clickCount == 2 { performTitleBarDoubleClick(window) }
                return
            }
            if movesWindow {
                var origin = window.frame.origin
                origin.x += event.deltaX
                origin.y -= event.deltaY
                window.setFrameOrigin(origin)
            } else if RecordingDrag.hasPassedThreshold(from: press.locationInWindow, to: event.locationInWindow) {
                if !beginFileDrag(event: event, at: press.locationInWindow, in: window) {
                    debugLog("📎 Recording drag not started (trim exporting or file gone)")
                }
                return
            }
        }
    }

    /// The system's title bar double-click setting (Desktop & Dock).
    private func performTitleBarDoubleClick(_ window: NSWindow) {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.miniaturize(nil)
        case "None": break
        default: window.zoom(nil)
        }
    }

    /// The title bar's file icon: AppKit's own drag would let Finder move the
    /// file out of the save folder, so it gets the same copy-only drag.
    func window(_ window: NSWindow, shouldDragDocumentWith event: NSEvent, from dragImageLocation: NSPoint, with pasteboard: NSPasteboard) -> Bool {
        _ = beginFileDrag(event: event, at: event.locationInWindow, in: window)
        return false
    }

    /// Starts a copy-only drag of the recording file, with the current frame
    /// as the drag image. Not while a committed trim is being written.
    @discardableResult
    private func beginFileDrag(event: NSEvent, at pressPoint: NSPoint, in window: NSWindow) -> Bool {
        guard window.attachedSheet == nil,
              let url = RecordingDrag.draggableFile(fileURL, trimInProgress: isExportingTrim),
              let frameView = window.contentView?.superview else { return false }
        let image = currentFrameImage() ?? {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 64, height: 64)
            return icon
        }()
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(
            RecordingDrag.dragImageFrame(imageSize: image.size, centeredAt: frameView.convert(pressPoint, from: nil)),
            contents: image
        )
        let session = frameView.beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        debugLog("📎 Recording drag started: \(url.lastPathComponent)")
        return true
    }

    /// The frame on screen, small, for the drag image. Nil if it cannot be
    /// decoded (the file icon is used instead).
    private func currentFrameImage() -> NSImage? {
        let scale = playerView.window?.backingScaleFactor ?? 2
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: fileURL))
        generator.appliesPreferredTrackTransform = true
        let side = RecordingDrag.maxImageDimension * scale
        generator.maximumSize = CGSize(width: side, height: side)
        // A nearby frame is fine for a drag image and decodes much faster.
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let time = playerView.player?.currentTime() ?? .zero
        guard let frame = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
        let size = NSSize(width: CGFloat(frame.width) / scale, height: CGFloat(frame.height) / scale)
        // Rounded, with a hairline edge, like a thumbnail in Finder.
        return NSImage(size: size, flipped: false) { rect in
            let radius = RecordingDrag.imageCornerRadius
            let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            NSImage(cgImage: frame, size: size).draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
            let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
            edge.lineWidth = 1
            NSColor.white.withAlphaComponent(0.35).setStroke()
            edge.stroke()
            return true
        }
    }

    // MARK: - NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Copy only: dropping on Finder must never move the recording out of
        // the save folder from under the player.
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        debugLog("📎 Recording drag ended: \(operation == .copy ? "dropped (copy)" : "cancelled")")
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if let titleFieldObserver {
            NotificationCenter.default.removeObserver(titleFieldObserver)
            self.titleFieldObserver = nil
        }
        playerView.player?.pause()
        playerView.player = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let titleBarMonitor {
            NSEvent.removeMonitor(titleBarMonitor)
            self.titleBarMonitor = nil
        }
        onClose?()
    }
}

/// A clear patch of title bar that does not move the window when pressed. The
/// window server decides title bar moves from the views that allow it, before
/// the app sees the press, so a drag that starts here can only be a file drag.
final class TitleBarGripView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
}
