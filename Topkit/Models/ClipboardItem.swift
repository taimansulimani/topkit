import Foundation
import AppKit

struct ClipboardItem: Identifiable, Codable {
    let id: UUID
    let content: String
    let type: ItemType
    /// Mutable so re-copying a pinned item can refresh its recency in place.
    var timestamp: Date
    var imageData: Data?
    /// Filename on disk for persisted full-resolution image (e.g. "UUID.png"). Used so we don't store large image data in UserDefaults.
    var imageFile: String?
    /// Stable content hash of the full-resolution image bytes. Used for cheap dedup
    /// without comparing megabytes of `Data`, and survives the in-memory bytes being freed.
    var imageHash: String?
    /// For `.file` items: the copied file paths. `content` holds a display string only;
    /// splitting it back apart breaks on paths that contain the separator, so copy-back
    /// uses this array. Optional so history persisted before the field existed still decodes.
    var filePaths: [String]?
    /// True while the item is pinned to the top of the history list. Optional so history
    /// persisted before the field existed still decodes; nil means unpinned.
    var isPinned: Bool?

    enum ItemType: String, Codable {
        case text
        case image
        case file
    }

    init(id: UUID = UUID(), content: String, type: ItemType, timestamp: Date = Date(), imageData: Data? = nil, imageFile: String? = nil, imageHash: String? = nil, filePaths: [String]? = nil, isPinned: Bool? = nil) {
        self.id = id
        self.content = content
        self.type = type
        self.timestamp = timestamp
        self.imageData = imageData
        self.imageFile = imageFile
        self.imageHash = imageHash
        self.filePaths = filePaths
        self.isPinned = isPinned
    }
    
    var preview: String {
        switch type {
        case .text:
            return String(content.prefix(100))
        case .image:
            return "Image"
        case .file:
            return content
        }
    }
}






