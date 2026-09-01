import Foundation

enum ScreenshotDirectoryValidator {
    /// Ensures the path exists, is a directory, and is writable. Returns a standardized directory URL, or nil.
    static func validatedScreenshotSaveDirectory(
        _ folderURL: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let standardized = folderURL.standardizedFileURL
        let path = standardized.path

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }

        guard fileManager.isWritableFile(atPath: path) else {
            return nil
        }

        return standardized
    }
}

