import XCTest
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

/// Delete in the recording player: Topkit's own temp files are removed,
/// anything else (the auto-saved copy in the user's folder) goes to the
/// Trash and is never hard-deleted.
final class RecordingDiscardTests: XCTestCase {

    private var root: URL!
    private var tempDir: URL!
    private var saveFolder: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingDiscardTests_\(UUID().uuidString)", isDirectory: true)
        // Stand-ins: "tmp" plays the app's temporary directory, "Desktop" the
        // user's chosen save folder. Siblings, so neither contains the other.
        tempDir = root.appendingPathComponent("tmp", isDirectory: true)
        saveFolder = root.appendingPathComponent("Desktop", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeFile(in folder: URL, named name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data("mov".utf8).write(to: url)
        return url
    }

    // MARK: discardMethod

    func testFileInTemporaryDirectoryIsRemoved() {
        let staging = tempDir.appendingPathComponent("Recording_inprogress_X.mov")
        XCTAssertEqual(RecordingDestination.discardMethod(for: staging, temporaryDirectory: tempDir), .removeTemporaryFile)
    }

    func testFileInSaveFolderGoesToTrash() {
        let saved = saveFolder.appendingPathComponent("Recording_2026-07-16_14-03-09.mov")
        XCTAssertEqual(RecordingDestination.discardMethod(for: saved, temporaryDirectory: tempDir), .moveToTrash)
    }

    func testSiblingFolderWithSharedPrefixIsNotTemporary() {
        // "tmp-other" starts with "tmp" as a string but is not inside it.
        let lookalike = root.appendingPathComponent("tmp-other/Recording.mov")
        XCTAssertEqual(RecordingDestination.discardMethod(for: lookalike, temporaryDirectory: tempDir), .moveToTrash)
    }

    func testTemporaryDirectoryItselfIsNotInsideItself() {
        XCTAssertFalse(RecordingDestination.isFile(tempDir, inside: tempDir))
    }

    func testDotDotEscapingTemporaryDirectoryGoesToTrash() {
        let escaped = tempDir.appendingPathComponent("../Desktop/Recording.mov")
        XCTAssertEqual(RecordingDestination.discardMethod(for: escaped, temporaryDirectory: tempDir), .moveToTrash)
    }

    func testRealTemporaryDirectoryResolvesSymlinks() {
        // /var/folders/... vs /private/var/folders/... must still match.
        let tmp = FileManager.default.temporaryDirectory
        let file = tmp.resolvingSymlinksInPath().appendingPathComponent("Trim_X.mov")
        XCTAssertEqual(RecordingDestination.discardMethod(for: file), .removeTemporaryFile)
    }

    // MARK: discardRecording

    func testDiscardRemovesTemporaryFileWithoutTrashing() throws {
        let staging = try makeFile(in: tempDir, named: "Recording_inprogress_X.mov")
        var trashed: [URL] = []
        let method = RecordingDestination.discardRecording(at: staging, temporaryDirectory: tempDir) { trashed.append($0) }
        XCTAssertEqual(method, .removeTemporaryFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertTrue(trashed.isEmpty)
    }

    func testDiscardTrashesSavedFileAndNeverRemovesIt() throws {
        let saved = try makeFile(in: saveFolder, named: "Recording.mov")
        var trashed: [URL] = []
        let method = RecordingDestination.discardRecording(at: saved, temporaryDirectory: tempDir) { trashed.append($0) }
        XCTAssertEqual(method, .moveToTrash)
        XCTAssertEqual(trashed, [saved])
        // The fake trash did nothing, so the file must still be there: the
        // save-folder path is never removed directly.
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
    }

    func testFailedTrashLeavesFileAndDoesNotFallBackToRemove() throws {
        let saved = try makeFile(in: saveFolder, named: "Recording.mov")
        struct TrashUnavailable: Error {}
        let method = RecordingDestination.discardRecording(at: saved, temporaryDirectory: tempDir) { _ in
            throw TrashUnavailable()
        }
        XCTAssertNil(method)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
    }

    func testMissingTemporaryFileReportsFailure() {
        let gone = tempDir.appendingPathComponent("Trim_gone.mov")
        XCTAssertNil(RecordingDestination.discardRecording(at: gone, temporaryDirectory: tempDir) { _ in })
    }
}
