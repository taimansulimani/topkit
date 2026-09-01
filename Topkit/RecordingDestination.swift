import AppKit

/// Where recordings land. Sandboxed: ~/Desktop (the default) needs a one-time
/// user grant via NSOpenPanel; the chosen folder is kept as a security-scoped
/// bookmark, mirroring the screenshot save-folder mechanism.
enum RecordingDestinationKeys {
    static let folder = "recordingSaveFolder"
    static let folderBookmark = "recordingSaveFolderBookmark"
}

enum RecordingDestination {

    /// Staging file inside the app container — always writable, no grant
    /// needed. The recording is written here and moved on stop (crash-safe:
    /// a dead recording never litters the destination folder).
    static func makeStagingURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Recording_inprogress_\(UUID().uuidString).mov")
    }

    /// True when a save folder has already been granted (bookmark stored).
    static var hasSaveFolder: Bool {
        UserDefaults.standard.data(forKey: RecordingDestinationKeys.folderBookmark) != nil
    }

    /// The real ~/Desktop (NSHomeDirectory() points at the sandbox container;
    /// getpwuid gives the true home). Used only to point the grant panel.
    static func realDesktopURL() -> URL? {
        guard let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir else { return nil }
        let homePath = FileManager.default.string(withFileSystemRepresentation: home, length: strlen(home))
        return URL(fileURLWithPath: homePath, isDirectory: true)
            .appendingPathComponent("Desktop", isDirectory: true)
    }

    /// One-time grant: open panel pre-pointed at the real Desktop. Stores the
    /// bookmark on success. Calls back with whether a folder is now available.
    /// Present BEFORE any overlay windows exist (the panel must be frontmost).
    static func requestSaveFolderGrant(completion: @escaping (Bool) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = realDesktopURL()
        panel.title = String(localized: "Choose Recording Save Folder")
        panel.message = String(localized: "Topkit needs one-time permission to save screen recordings here. Desktop is the default — click Grant Access, or pick another folder.")
        panel.prompt = String(localized: "Grant Access")
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                completion(false)
                return
            }
            store(folderURL: url)
            completion(true)
        }
    }

    /// Persist a chosen folder (also used by Preferences).
    static func store(folderURL: URL) {
        if let bookmark = try? folderURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(bookmark, forKey: RecordingDestinationKeys.folderBookmark)
        }
        UserDefaults.standard.set(folderURL.path, forKey: RecordingDestinationKeys.folder)
    }

    /// Resolve the stored folder and run `body` with its security scope
    /// active. Refreshes a stale bookmark in place (same gotcha as
    /// screenshots: refresh must happen while the scope is started).
    /// Returns nil when no folder is stored or `body` throws.
    static func withSaveFolderAccess<T>(_ body: (URL) throws -> T) -> T? {
        let defaults = UserDefaults.standard
        guard let bookmarkData = defaults.data(forKey: RecordingDestinationKeys.folderBookmark) else { return nil }
        var isStale = false
        guard let folderURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        let started = folderURL.startAccessingSecurityScopedResource()
        defer { if started { folderURL.stopAccessingSecurityScopedResource() } }
        if isStale, started,
           let refreshed = try? folderURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
           ) {
            defaults.set(refreshed, forKey: RecordingDestinationKeys.folderBookmark)
        }
        guard let validated = ScreenshotDirectoryValidator.validatedScreenshotSaveDirectory(folderURL) else { return nil }
        return try? body(validated)
    }

    /// Long-lived security scope for the save folder — used while the player
    /// window has a recording open (AVPlayer/export read the file lazily, long
    /// after the save's own scope has ended; without an active scope the
    /// sandbox denies the reads and the player shows nothing). Returns the
    /// scoped folder URL to hold on to and pass to `endSaveFolderAccess`.
    static func beginSaveFolderAccess() -> URL? {
        guard let bookmarkData = UserDefaults.standard.data(forKey: RecordingDestinationKeys.folderBookmark) else { return nil }
        var isStale = false
        guard let folderURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        guard folderURL.startAccessingSecurityScopedResource() else { return nil }
        return folderURL
    }

    static func endSaveFolderAccess(_ folderURL: URL) {
        folderURL.stopAccessingSecurityScopedResource()
    }

    /// Move a finished staging file into the destination folder with a
    /// timestamped name. Returns the final URL, or nil on failure (the
    /// staging file is left in place so nothing is lost).
    static func moveIntoSaveFolder(stagingURL: URL, date: Date = Date()) -> URL? {
        let moved: URL? = withSaveFolderAccess { folder in
            let name = RecordingFilename.make(date: date) { candidate in
                FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path)
            }
            let destination = folder.appendingPathComponent(name)
            try FileManager.default.moveItem(at: stagingURL, to: destination)
            return destination
        }
        return moved
    }

    /// Rename `originalURL` (inside the granted folder) to `newBaseName`,
    /// keeping the original extension. Path separators are stripped; blank
    /// names are rejected; collisions get " 2", " 3", … appended. Returns the
    /// new URL, or nil on failure (the original is left untouched).
    static func renameRecording(at originalURL: URL, to newBaseName: String) -> URL? {
        let ext = originalURL.pathExtension
        let trimmed = newBaseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = trimmed
            .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
            .joined(separator: "-")
        guard !sanitized.isEmpty else { return nil }
        return withSaveFolderAccess { folder in
            let fm = FileManager.default
            func url(for name: String) -> URL {
                folder.appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
            }
            var candidate = url(for: sanitized)
            // Renaming to the same name is a no-op success, not a collision.
            if candidate.standardizedFileURL == originalURL.standardizedFileURL { return originalURL }
            var counter = 2
            while fm.fileExists(atPath: candidate.path) {
                candidate = url(for: "\(sanitized) \(counter)")
                counter += 1
            }
            try fm.moveItem(at: originalURL, to: candidate)
            return candidate
        }
    }

    /// Atomically replace `originalURL` (inside the granted folder) with
    /// `newContentURL` — used by trim-and-save. Returns the (possibly new)
    /// URL of the replaced file, or nil on failure.
    static func replaceRecording(at originalURL: URL, with newContentURL: URL) -> URL? {
        let replaced: URL?? = withSaveFolderAccess { _ in
            try FileManager.default.replaceItemAt(originalURL, withItemAt: newContentURL) ?? originalURL
        }
        return replaced ?? nil
    }
}
