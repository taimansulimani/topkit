import AppKit
import XCTest
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

/// The on-screen renderer derives a text annotation's frame from its current text and
/// font size (`effectiveFrame`), while the export renderer used the raw stored frame.
/// A stale stored height therefore put the text in one place on screen and another in
/// the saved file. Both paths must now agree.
final class AnnotationRendererTests: XCTestCase {

    private func textAnnotation(storedFrame: NSRect) -> Annotation {
        Annotation(
            id: UUID(),
            type: .text,
            frame: storedFrame,
            color: .red,
            thickness: 2,
            text: "Hello",
            fontSize: 24,
            startPoint: nil,
            endPoint: nil,
            pathPoints: nil,
            stickerPointerDirection: nil
        )
    }

    /// A stored frame far taller than the rendered text is exactly the stale-height case.
    func testExportUsesTheRenderedTextFrameNotTheStoredOne() {
        let stale = NSRect(x: 20, y: 20, width: 400, height: 300)
        let annotation = textAnnotation(storedFrame: stale)

        let resolved = AnnotationRenderer.Context.export.textFrame(annotation)

        XCTAssertEqual(resolved.origin, stale.origin,
                       "The origin is authoritative and must be preserved")
        XCTAssertLessThan(resolved.height, stale.height,
                          "Height must be recomputed from the rendered text, not taken from the stale stored frame")
    }

    /// Guards against the default silently reverting to { $0.frame }.
    func testExportContextResolvesNonTextAnnotationsToTheirStoredFrame() {
        let frame = NSRect(x: 5, y: 5, width: 50, height: 50)
        let rect = Annotation(
            id: UUID(),
            type: .rectangle,
            frame: frame,
            color: .blue,
            thickness: 3,
            text: nil,
            fontSize: nil,
            startPoint: nil,
            endPoint: nil,
            pathPoints: nil,
            stickerPointerDirection: nil
        )

        XCTAssertEqual(AnnotationRenderer.Context.export.textFrame(rect), frame)
    }

    /// Empty text has no rendered extent, so the stored frame stands.
    func testEmptyTextFallsBackToTheStoredFrame() {
        var annotation = textAnnotation(storedFrame: NSRect(x: 1, y: 2, width: 3, height: 4))
        annotation.text = ""

        XCTAssertEqual(AnnotationRenderer.textFrame(for: annotation), annotation.frame)
    }
}
