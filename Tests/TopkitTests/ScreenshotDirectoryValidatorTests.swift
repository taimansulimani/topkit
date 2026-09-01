import Foundation
import XCTest
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

final class ScreenshotDirectoryValidatorTests: XCTestCase {
    func testMissingPathReturnsNil() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let missing = tempRoot.appendingPathComponent("missing", isDirectory: true)
        let validated = ScreenshotDirectoryValidator.validatedScreenshotSaveDirectory(missing, fileManager: fm)
        XCTAssertNil(validated)
    }

    func testNonDirectoryReturnsNil() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let fileURL = tempRoot.appendingPathComponent("notADir.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: fileURL)

        let validated = ScreenshotDirectoryValidator.validatedScreenshotSaveDirectory(fileURL, fileManager: fm)
        XCTAssertNil(validated)
    }

    func testWritableDirectoryReturnsStandardizedURL() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let validated = ScreenshotDirectoryValidator.validatedScreenshotSaveDirectory(tempRoot, fileManager: fm)
        XCTAssertNotNil(validated)
        XCTAssertEqual(validated?.path, tempRoot.standardizedFileURL.path)
    }

    func testNonWritableDirectoryReturnsNil_bestEffort() throws {
        // Best-effort: permissions behavior can vary depending on filesystem and host privileges.
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let protected = tempRoot.appendingPathComponent("protected", isDirectory: true)
        try fm.createDirectory(at: protected, withIntermediateDirectories: true)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: protected.path) }

        try? fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: protected.path) // r-x for owner; not writable
        let validated = ScreenshotDirectoryValidator.validatedScreenshotSaveDirectory(protected, fileManager: fm)

        // If the host still reports writable, this assertion could fail. We'll only assert nil when it isn't writable.
        if fm.isWritableFile(atPath: protected.path) {
            return
        }
        XCTAssertNil(validated)
    }
}

