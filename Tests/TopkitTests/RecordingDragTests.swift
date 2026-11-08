import XCTest
import AppKit
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

final class RecordingDragTests: XCTestCase {

    // MARK: - Which file gets dragged

    private let recording = URL(fileURLWithPath: "/Users/me/Desktop/Recording_2026-11-07_12-00-00.mov")

    func testDragsTheRecordingFileItself() {
        // Trims are committed by overwriting this file and captions are burned
        // in while recording, so the saved file is what gets dragged.
        XCTAssertEqual(RecordingDrag.draggableFile(recording, trimInProgress: false, fileExists: { _ in true }), recording)
    }

    func testNoDragWhileTrimIsExporting() {
        // The file on disk is about to be replaced by the trimmed one.
        XCTAssertNil(RecordingDrag.draggableFile(recording, trimInProgress: true, fileExists: { _ in true }))
    }

    // MARK: - Click vs drag on the title bar

    func testShortMoveIsAClick() {
        XCTAssertFalse(RecordingDrag.hasPassedThreshold(from: NSPoint(x: 100, y: 10), to: NSPoint(x: 101, y: 11)))
    }

    func testMovePastThresholdStartsTheDrag() {
        XCTAssertTrue(RecordingDrag.hasPassedThreshold(from: NSPoint(x: 100, y: 10), to: NSPoint(x: 103, y: 10)))
        XCTAssertTrue(RecordingDrag.hasPassedThreshold(from: NSPoint(x: 100, y: 10), to: NSPoint(x: 98, y: 13)))
    }

    func testNoDragWhenFileIsGone() {
        XCTAssertNil(RecordingDrag.draggableFile(recording, trimInProgress: false, fileExists: { _ in false }))
    }

    func testNoDragForNonFileURL() {
        let web = URL(string: "https://topkitapp.com/video.mov")!
        XCTAssertNil(RecordingDrag.draggableFile(web, trimInProgress: false, fileExists: { _ in true }))
    }

    func testRealFileOnDiskIsDraggable() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RecordingDragTests_\(UUID().uuidString).mov")
        try Data([0]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(RecordingDrag.draggableFile(url, trimInProgress: false), url)
    }

    // MARK: - Drag image

    func testDragImageScaledToFitAndCentred() {
        let frame = RecordingDrag.dragImageFrame(imageSize: NSSize(width: 320, height: 180), centeredAt: NSPoint(x: 100, y: 100))
        XCTAssertEqual(frame.width, 80, accuracy: 0.001)
        XCTAssertEqual(frame.height, 45, accuracy: 0.001)
        XCTAssertEqual(frame.midX, 100, accuracy: 0.001)
        XCTAssertEqual(frame.midY, 100, accuracy: 0.001)
    }

    func testDragImagePortraitFitsLongestSide() {
        let frame = RecordingDrag.dragImageFrame(imageSize: NSSize(width: 100, height: 400), centeredAt: .zero)
        XCTAssertEqual(frame.height, 80, accuracy: 0.001)
        XCTAssertEqual(frame.width, 20, accuracy: 0.001)
    }

    func testSmallDragImageIsNotEnlarged() {
        let frame = RecordingDrag.dragImageFrame(imageSize: NSSize(width: 64, height: 64), centeredAt: NSPoint(x: 10, y: 10))
        XCTAssertEqual(frame, NSRect(x: -22, y: -22, width: 64, height: 64))
    }

    func testZeroSizeImageDoesNotCrash() {
        let frame = RecordingDrag.dragImageFrame(imageSize: .zero, centeredAt: NSPoint(x: 5, y: 5))
        XCTAssertEqual(frame, NSRect(x: 5, y: 5, width: 0, height: 0))
    }
}

/// Only the file's name in the player's title bar drags the file; the rest of
/// the title bar moves the window as usual.
final class RecordingPlayerTitleBarTests: XCTestCase {

    func testOnlyTheFileNameDragsTheFile() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Recording_test.mov")
        let controller = RecordingPlayerWindowController(fileURL: url)
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        defer { window.close() }
        XCTAssertTrue(window.isMovable)

        let field = try XCTUnwrap(RecordingPlayerWindowController.titleField(in: window))
        let middle = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
        XCTAssertTrue(controller.isFileNameDragPoint(middle, in: window))
        // Pressing the name never starts a window move: the window server moves
        // a window only from views that allow it.
        let grip = try XCTUnwrap(field.superview?.subviews.first { $0 is TitleBarGripView })
        XCTAssertFalse(grip.mouseDownCanMoveWindow)
        XCTAssertTrue(grip.frame.contains(field.superview!.convert(middle, from: nil)))

        // Empty title bar between the traffic lights and the name.
        let titleBarY = (window.contentLayoutRect.maxY + window.frame.height) / 2
        let textWidth = field.attributedStringValue.size().width
        let nameLeft = middle.x - textWidth / 2
        XCTAssertFalse(controller.isFileNameDragPoint(NSPoint(x: (90 + nameLeft - 30) / 2, y: titleBarY), in: window))
        // Inside the video.
        XCTAssertFalse(controller.isFileNameDragPoint(NSPoint(x: middle.x, y: 100), in: window))
    }
}
