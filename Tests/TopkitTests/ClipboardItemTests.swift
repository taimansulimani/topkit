import Foundation
import XCTest
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

final class ClipboardItemTests: XCTestCase {
    func testCodableRoundTripPreservesImageMetadataWithoutImageData() throws {
        let id = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let item = ClipboardItem(
            id: id,
            content: "Image",
            type: .image,
            timestamp: timestamp,
            imageData: nil,
            imageFile: "test-\(id.uuidString).png"
        )

        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(ClipboardItem.self, from: data)

        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.type, .image)
        XCTAssertEqual(decoded.imageFile, item.imageFile)
        XCTAssertNil(decoded.imageData)
    }

    func testPreviewForTextImageAndFile() {
        let text = ClipboardItem(content: String(repeating: "A", count: 120), type: .text)
        XCTAssertEqual(text.preview.count, 100)

        let image = ClipboardItem(content: "Image", type: .image)
        XCTAssertEqual(image.preview, "Image")

        let file = ClipboardItem(content: "/tmp/example.png", type: .file)
        XCTAssertEqual(file.preview, "/tmp/example.png")
    }
}

