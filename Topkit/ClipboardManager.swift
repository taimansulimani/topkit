import Foundation
import AppKit
import Combine
import CryptoKit

class ClipboardManager: ObservableObject {
    static let shared = ClipboardManager()

    @Published var clipboardHistory: [ClipboardItem] = []
    private var pasteboard: NSPasteboard
    private var lastChangeCount: Int
    private var timer: Timer?
    /// Polls the auto-clear schedule when the feature is enabled (nil when disabled).
    private var autoClearTimer: Timer?

    /// Key used to encrypt the persisted history blob and image files at rest.
    /// Resolved once at init (off the hot paths) so save/load/thumbnailing stay cheap.
    private let encryptionKey: SymmetricKey
    /// Serial queue for best-effort disk hygiene (orphan-file pruning) so the directory
    /// scan never runs on the main thread during a clipboard change.
    private let maintenanceQueue = DispatchQueue(label: "topkit.clipboard.maintenance", qos: .utility)

    private var maxHistorySize: Int {
        let value = UserDefaults.standard.object(forKey: "maxHistorySize") as? Int ?? 100
        return min(500, max(10, value))
    }

    /// Full-resolution clipboard images are stored here; only metadata lives in UserDefaults.
    private var clipboardImagesDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Topkit", isDirectory: true).appendingPathComponent("clipboard_images", isDirectory: true)
        return dir
    }

    private init() {
        pasteboard = NSPasteboard.general
        lastChangeCount = pasteboard.changeCount
        encryptionKey = ClipboardKeyStore.key()
        try? ClipboardImagesStorageHelpers.createClipboardImagesDirectoryIfNeeded(at: clipboardImagesDirectory)
        startMonitoring()
        loadHistory()
        refreshAutoClearSchedule()
    }
    
    func startMonitoring() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
    }
    
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }
    
    private func checkClipboard() {
        let currentChangeCount = pasteboard.changeCount
        guard currentChangeCount != lastChangeCount else { return }
        
        lastChangeCount = currentChangeCount

        // Skip entries marked concealed (passwords from 1Password, Bitwarden), transient,
        // or auto-generated (nspasteboard.org conventions)
        if ClipboardPasteboardHelpers.shouldSkipPasteboardDueToSensitiveType(pasteboard) {
            return
        }
        
        // Check for text
        if let string = pasteboard.string(forType: .string) {
            let item = ClipboardItem(content: string, type: .text)
            addToHistory(item)
            return
        }
        
        // Check for image — use PNG at full resolution (no TIFF, no downscale)
        if let imageData = ImageHelpers.imageDataFromPasteboard(pasteboard) {
            let item = ClipboardItem(
                content: "Image",
                type: .image,
                imageData: imageData,
                imageHash: ClipboardHistoryStorageHelpers.imageHash(imageData)
            )
            addToHistory(item)
            return
        }
        
        // Check for files
        if let files = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [NSURL],
           !files.isEmpty {
            let paths = files.compactMap { $0.path }
            let item = ClipboardItem(content: paths.joined(separator: ", "), type: .file, filePaths: paths)
            addToHistory(item)
        }
    }
    
    private func addToHistory(_ item: ClipboardItem) {
        // Dedup (images by stable hash, text/files by content) and insert below the
        // pinned block so pins stay on top. Note: images persisted before the hash
        // field existed won't dedup against a fresh copy until they age out.
        clipboardHistory = ClipboardPinningHelpers.addingItem(item, to: clipboardHistory)

        // Limit history size (pinned items live at the head, so they survive the cap)
        clipboardHistory = ClipboardHistoryStorageHelpers.capHistory(clipboardHistory, maxHistorySize: maxHistorySize)

        saveHistory()

        // Notify that clipboard changed
        NotificationCenter.default.post(name: NSNotification.Name("ClipboardChanged"), object: nil)
    }

    /// Pins or unpins an item. Pinning moves it to the top of the list (it becomes
    /// item 1); unpinning slots it back among the unpinned items by recency.
    func togglePin(itemID: UUID) {
        clipboardHistory = ClipboardPinningHelpers.togglingPin(clipboardHistory, id: itemID)
        saveHistory()
        NotificationCenter.default.post(name: NSNotification.Name("ClipboardChanged"), object: nil)
    }
    
    func copyToClipboard(_ item: ClipboardItem) {
        pasteboard.clearContents()
        
        switch item.type {
        case .text:
            pasteboard.setString(item.content, forType: .string)
        case .image:
            if let imageData = fullImageData(for: item),
               let image = NSImage(data: imageData) {
                pasteboard.writeObjects([image])
            }
        case .file:
            // Legacy items (pre-filePaths) fall back to splitting the display string.
            let paths = item.filePaths ?? item.content.components(separatedBy: ", ")
            let urls = paths.map { URL(fileURLWithPath: $0) }
            pasteboard.writeObjects(urls as [NSPasteboardWriting])
        }
        
        lastChangeCount = pasteboard.changeCount
    }

    /// Full-resolution image bytes for an item. In-memory bytes are freed once persisted,
    /// so this lazily reads the PNG back from disk on demand (copy-back, export, thumbnailing).
    func fullImageData(for item: ClipboardItem) -> Data? {
        if let data = item.imageData { return data }
        guard let filename = item.imageFile else { return nil }
        let fileURL = clipboardImagesDirectory.appendingPathComponent(filename)
        guard let stored = try? Data(contentsOf: fileURL) else { return nil }
        // Encrypted by `saveHistory`; legacy plaintext PNGs decrypt-fail and pass through.
        return ClipboardCrypto.decryptOrPassthrough(stored, key: encryptionKey)
    }

    func clearHistory() {
        clipboardHistory.removeAll()
        // Remove all persisted full-res image files
        if let files = try? FileManager.default.contentsOfDirectory(at: clipboardImagesDirectory, includingPropertiesForKeys: nil) {
            for url in files where url.pathExtension.lowercased() == "png" {
                try? FileManager.default.removeItem(at: url)
            }
        }
        saveHistory()
    }

    // MARK: - Scheduled auto-clear

    /// UserDefaults keys backing the auto-clear schedule (mirrored by the Clipboard preferences UI).
    enum AutoClearKeys {
        static let enabled = "autoClearEnabled"
        static let mode = "autoClearMode"
        static let intervalValue = "autoClearIntervalValue"
        static let intervalUnit = "autoClearIntervalUnit"
        static let hour = "autoClearHour"
        static let minute = "autoClearMinute"
        static let weekday = "autoClearWeekday"
        /// When history was last auto-cleared, or the baseline set when the schedule was enabled.
        static let lastRun = "autoClearLastRun"
    }

    /// Builds the current schedule from UserDefaults, clamping stored values to valid ranges.
    static func autoClearConfig(_ defaults: UserDefaults = .standard) -> ClipboardAutoClearConfig {
        ClipboardAutoClearConfig(
            enabled: defaults.bool(forKey: AutoClearKeys.enabled),
            mode: ClipboardAutoClearConfig.Mode(rawValue: defaults.string(forKey: AutoClearKeys.mode) ?? "") ?? .daily,
            intervalValue: max(1, defaults.object(forKey: AutoClearKeys.intervalValue) as? Int ?? 1),
            intervalUnit: ClipboardAutoClearConfig.IntervalUnit(rawValue: defaults.string(forKey: AutoClearKeys.intervalUnit) ?? "") ?? .days,
            hour: min(23, max(0, defaults.object(forKey: AutoClearKeys.hour) as? Int ?? 3)),
            minute: min(59, max(0, defaults.object(forKey: AutoClearKeys.minute) as? Int ?? 0)),
            weekday: min(7, max(1, defaults.object(forKey: AutoClearKeys.weekday) as? Int ?? 2))
        )
    }

    /// (Re)arms or disarms the auto-clear timer to match the saved schedule. Call at launch and
    /// whenever the schedule changes in Preferences. Seeds a "now" baseline on first enable so
    /// turning the feature on never wipes existing history immediately, and clears that baseline
    /// when disabled so a later re-enable starts fresh.
    func refreshAutoClearSchedule() {
        autoClearTimer?.invalidate()
        autoClearTimer = nil

        let defaults = UserDefaults.standard
        guard Self.autoClearConfig(defaults).enabled else {
            defaults.removeObject(forKey: AutoClearKeys.lastRun)
            return
        }

        if defaults.object(forKey: AutoClearKeys.lastRun) == nil {
            defaults.set(Date(), forKey: AutoClearKeys.lastRun)
        }

        // Evaluate immediately (catches daily/weekly occurrences missed while the app was closed),
        // then poll once a minute — fine-grained enough for hour/day/week schedules.
        evaluateAutoClear()
        autoClearTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.evaluateAutoClear()
        }
    }

    private func evaluateAutoClear() {
        let defaults = UserDefaults.standard
        let config = Self.autoClearConfig(defaults)
        let lastRun = defaults.object(forKey: AutoClearKeys.lastRun) as? Date
        guard ClipboardAutoClearPolicy.shouldClear(now: Date(), lastClear: lastRun, config: config) else { return }
        clearHistory()
        defaults.set(Date(), forKey: AutoClearKeys.lastRun)
    }

    private func saveHistory() {
        // Persist each full-resolution image to disk exactly once, then drop its in-memory
        // bytes so history holds only metadata (RAM stays flat regardless of image count/size).
        for index in clipboardHistory.indices where clipboardHistory[index].type == .image {
            // Already on disk: just free the in-memory copy.
            if let filename = clipboardHistory[index].imageFile,
               FileManager.default.fileExists(atPath: clipboardImagesDirectory.appendingPathComponent(filename).path) {
                clipboardHistory[index].imageData = nil
                continue
            }
            // Not yet persisted: write once, record the filename, free the bytes.
            guard let imageData = clipboardHistory[index].imageData else { continue }
            let filename = "\(clipboardHistory[index].id.uuidString).png"
            let fileURL = clipboardImagesDirectory.appendingPathComponent(filename)
            do {
                let encrypted = try ClipboardCrypto.encrypt(imageData, key: encryptionKey)
                try encrypted.write(to: fileURL, options: .atomic)
                try ClipboardImagesStorageHelpers.setPNGFilePermissions0600(at: fileURL.path)
                clipboardHistory[index].imageFile = filename
                clipboardHistory[index].imageData = nil
            } catch {
                debugLog("⚠️ Failed to write clipboard image \(filename): \(error)")
            }
        }

        // Prune orphan image files (items no longer in history). The directory scan + removals
        // run off-main; the kept-set is snapshotted here so it stays consistent.
        let imageIds = Set(clipboardHistory.filter { $0.type == .image }.map { $0.id.uuidString })
        let imagesDir = clipboardImagesDirectory
        maintenanceQueue.async {
            _ = ClipboardHistoryStorageHelpers.pruneOrphanPNGFiles(
                in: imagesDir,
                keepingImageBaseNames: imageIds,
                fileManager: FileManager.default
            )
        }

        // imageData is already nil in memory for persisted images; encode as-is.
        // Encrypt the (small, text+metadata) blob so clipboard text never sits in
        // cleartext in the app's preferences plist. Encode + encrypt run on the serial
        // maintenance queue (ClipboardItem is a value type, so the snapshot is safe and
        // serial ordering keeps last-write-wins) — a multi-MB copied text would otherwise
        // stall the main thread on every subsequent clipboard change.
        let snapshot = clipboardHistory
        let key = encryptionKey
        maintenanceQueue.async {
            if let encoded = try? JSONEncoder().encode(snapshot),
               let encrypted = try? ClipboardCrypto.encrypt(encoded, key: key) {
                UserDefaults.standard.set(encrypted, forKey: "clipboardHistory")
            }
        }
    }

    private func loadHistory() {
        // Decrypt the stored blob; a legacy cleartext-JSON blob decrypt-fails and passes
        // through unchanged, then gets re-encrypted on the next save.
        if let stored = UserDefaults.standard.data(forKey: "clipboardHistory"),
           let decoded = try? JSONDecoder().decode(
               [ClipboardItem].self,
               from: ClipboardCrypto.decryptOrPassthrough(stored, key: encryptionKey)
           ) {
            // Keep only metadata resident; full-res images are read lazily from disk
            // via `fullImageData(for:)` when actually needed (copy-back, export, thumbnail).
            clipboardHistory = ClipboardPinningHelpers.normalized(decoded.map { item in
                var m = item
                m.imageData = nil
                return m
            })
            if clipboardHistory.count > maxHistorySize {
                clipboardHistory = ClipboardHistoryStorageHelpers.capHistory(clipboardHistory, maxHistorySize: maxHistorySize)
                saveHistory()
            }
            debugLog("📋 Loaded \(clipboardHistory.count) clipboard items from storage")
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: NSNotification.Name("ClipboardChanged"), object: nil)
            }
        } else {
            debugLog("📋 No clipboard history found in storage")
        }
    }
}


