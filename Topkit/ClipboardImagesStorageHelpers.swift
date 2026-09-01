import Foundation

enum ClipboardImagesStorageHelpers {
    /// Creates the clipboard images directory with `0700` (owner rwx only).
    static func createClipboardImagesDirectoryIfNeeded(at url: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    /// Applies `0600` to a persisted PNG file path.
    static func setPNGFilePermissions0600(at path: String, fileManager: FileManager = .default) throws {
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}
