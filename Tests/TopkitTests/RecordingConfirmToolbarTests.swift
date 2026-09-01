import AppKit
import XCTest
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

/// The recording confirm toolbar (Start Recording / Cancel) also exposes Subtitles + Audio
/// toggles that share the same UserDefaults keys as Preferences.
final class RecordingConfirmToolbarTests: XCTestCase {

    private func findCheckbox(in view: NSView, title: String) -> NSButton? {
        for sub in view.subviews {
            if let button = sub as? NSButton, button.title == title { return button }
            if let found = findCheckbox(in: sub, title: title) { return found }
        }
        return nil
    }

    private func makeView(showsRecordingOptions: Bool) -> SelectionConfirmView {
        SelectionConfirmView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            selectionRect: NSRect(x: 100, y: 100, width: 200, height: 200),
            primaryTitle: "Start Recording",
            primaryIsDestructive: true,
            allowsResize: true,
            showsRecordingOptions: showsRecordingOptions
        )
    }

    func testRecordingToolbarShowsSubtitlesAndAudioToggles() {
        let view = makeView(showsRecordingOptions: true)
        XCTAssertNotNil(findCheckbox(in: view, title: "Subtitles"), "Recording toolbar must show a Subtitles toggle")
        XCTAssertNotNil(findCheckbox(in: view, title: "Audio"), "Recording toolbar must show an Audio toggle")
    }

    func testNonRecordingToolbarHidesToggles() {
        let view = makeView(showsRecordingOptions: false)
        XCTAssertNil(findCheckbox(in: view, title: "Subtitles"))
        XCTAssertNil(findCheckbox(in: view, title: "Audio"))
    }

    func testTogglesReflectAndPersistSharedPrefs() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: "recordingDictationSubtitles")
        defaults.set(false, forKey: "recordingMicrophoneAudio")

        let view = makeView(showsRecordingOptions: true)
        var subtitlesCallback: Bool?
        var audioCallback: Bool?
        view.onSubtitlesToggled = { subtitlesCallback = $0 }
        view.onMicAudioToggled = { audioCallback = $0 }

        guard let subtitles = findCheckbox(in: view, title: "Subtitles"),
              let audio = findCheckbox(in: view, title: "Audio") else {
            return XCTFail("Toggles must exist")
        }
        // Initial state mirrors the (false) prefs.
        XCTAssertEqual(subtitles.state, .off)
        XCTAssertEqual(audio.state, .off)

        // Simulate the user switching them on.
        subtitles.state = .on
        _ = NSApp.sendAction(subtitles.action!, to: subtitles.target, from: subtitles)
        audio.state = .on
        _ = NSApp.sendAction(audio.action!, to: audio.target, from: audio)

        XCTAssertTrue(defaults.bool(forKey: "recordingDictationSubtitles"), "Subtitles toggle must persist to the shared pref")
        XCTAssertTrue(defaults.bool(forKey: "recordingMicrophoneAudio"), "Audio toggle must persist to the shared pref")
        XCTAssertEqual(subtitlesCallback, true, "Subtitles toggle must notify the recording session")
        XCTAssertEqual(audioCallback, true, "Audio toggle must notify the recording session")
    }
}
