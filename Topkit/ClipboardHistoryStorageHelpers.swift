import Foundation
import CryptoKit

enum ClipboardHistoryStorageHelpers {
    /// Stable SHA-256 hex digest of image bytes. Used to dedup clipboard images cheaply
    /// (compare 64 chars instead of full `Data`) and consistently across app launches.
    static func imageHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Caps history to `maxHistorySize` by keeping the newest items first.
    static func capHistory(_ history: [ClipboardItem], maxHistorySize: Int) -> [ClipboardItem] {
        guard maxHistorySize > 0 else { return [] }
        if history.count <= maxHistorySize { return history }
        return Array(history.prefix(maxHistorySize))
    }

    /// Prunes orphan `.png` files from `directoryURL` by keeping only image base-names present in `keepingImageBaseNames`.
    ///
    /// - Returns: the number of files removed (best-effort; errors are ignored for parity with app behavior).
    static func pruneOrphanPNGFiles(
        in directoryURL: URL,
        keepingImageBaseNames: Set<String>,
        fileManager: FileManager = .default
    ) -> Int {
        guard let files = try? fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) else {
            return 0
        }

        var removed = 0
        for url in files where url.pathExtension.lowercased() == "png" {
            let base = url.deletingPathExtension().lastPathComponent
            guard !keepingImageBaseNames.contains(base) else { continue }

            do {
                try fileManager.removeItem(at: url)
                removed += 1
            } catch {
                // Keep best-effort behavior: pruning is a hygiene operation.
            }
        }
        return removed
    }
}

