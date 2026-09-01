import Foundation
import XCTest
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

final class ClipboardHistoryStorageHelpersTests: XCTestCase {
    func testCapHistoryKeepsNewestPrefix() {
        let items: [ClipboardItem] = (0..<5).map { i in
            ClipboardItem(content: "Item \(i)", type: .text, timestamp: Date(timeIntervalSince1970: TimeInterval(i)))
        }

        let capped = ClipboardHistoryStorageHelpers.capHistory(items, maxHistorySize: 3)
        XCTAssertEqual(capped.count, 3)
        XCTAssertEqual(capped.map { $0.content }, ["Item 0", "Item 1", "Item 2"])
    }

    func testImageHashIsStableAndDistinct() {
        let a = Data([0x01, 0x02, 0x03, 0x04])
        let b = Data([0x01, 0x02, 0x03, 0x05])

        // Stable: same bytes hash identically across calls (and runs).
        XCTAssertEqual(ClipboardHistoryStorageHelpers.imageHash(a), ClipboardHistoryStorageHelpers.imageHash(a))
        // Distinct: different bytes hash differently.
        XCTAssertNotEqual(ClipboardHistoryStorageHelpers.imageHash(a), ClipboardHistoryStorageHelpers.imageHash(b))
        // SHA-256 hex digest is 64 chars.
        XCTAssertEqual(ClipboardHistoryStorageHelpers.imageHash(a).count, 64)
    }

    func testPruneOrphanPNGFiles() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        func writePng(named name: String) throws {
            let fileURL = tempRoot.appendingPathComponent(name).appendingPathExtension("png")
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: fileURL)
        }

        try writePng(named: "keep")
        try writePng(named: "a")
        try writePng(named: "b")

        let removed = ClipboardHistoryStorageHelpers.pruneOrphanPNGFiles(
            in: tempRoot,
            keepingImageBaseNames: ["keep"],
            fileManager: fm
        )

        XCTAssertEqual(removed, 2)

        let remaining = (try? fm.contentsOfDirectory(at: tempRoot, includingPropertiesForKeys: nil).filter { $0.pathExtension.lowercased() == "png" }) ?? []
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.deletingPathExtension().lastPathComponent, "keep")
    }
}

