import Foundation
import XCTest
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

final class ClipboardImagesPermissionsTests: XCTestCase {
    func testCreateDirectoryUses0700() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let dir = root.appendingPathComponent("clipboard_images", isDirectory: true)
        try ClipboardImagesStorageHelpers.createClipboardImagesDirectoryIfNeeded(at: dir, fileManager: fm)

        let attrs = try fm.attributesOfItem(atPath: dir.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perms & 0o777, 0o700)
    }

    func testPNGFileUses0600() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("test.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: fileURL)
        try ClipboardImagesStorageHelpers.setPNGFilePermissions0600(at: fileURL.path, fileManager: fm)

        let attrs = try fm.attributesOfItem(atPath: fileURL.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perms & 0o777, 0o600)
    }
}
