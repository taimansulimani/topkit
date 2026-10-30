import XCTest
import AppKit
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

/// Permission prompts must open only after Topkit is the active app (TEC-250).
final class ActivationWaitTests: XCTestCase {

    private var center: NotificationCenter!
    private var scheduled: [(delay: TimeInterval, work: () -> Void)] = []
    private var runs = 0

    override func setUp() {
        super.setUp()
        center = NotificationCenter()
        scheduled = []
        runs = 0
    }

    private func start(active: Bool, timeout: TimeInterval = 0.75) {
        ActivationWait.start(
            isActive: { active },
            notificationCenter: center,
            timeout: timeout,
            schedule: { delay, work in self.scheduled.append((delay, work)) },
            body: { self.runs += 1 }
        )
    }

    private func becomeActive() {
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    func testRunsImmediatelyWhenAlreadyActive() {
        start(active: true)
        XCTAssertEqual(runs, 1)
        XCTAssertTrue(scheduled.isEmpty, "no timeout needed when already active")
        becomeActive()
        XCTAssertEqual(runs, 1)
    }

    func testWaitsForActivationBeforeRunning() {
        start(active: false)
        XCTAssertEqual(runs, 0, "prompt must not open while another app is frontmost")
        becomeActive()
        XCTAssertEqual(runs, 1)
    }

    func testTimeoutRunsWhenActivationNeverArrives() {
        start(active: false, timeout: 0.4)
        XCTAssertEqual(scheduled.count, 1)
        XCTAssertEqual(scheduled[0].delay, 0.4)
        scheduled[0].work()
        XCTAssertEqual(runs, 1)
    }

    func testRunsOnlyOnceWhenActivationThenTimeout() {
        start(active: false)
        becomeActive()
        scheduled[0].work()
        becomeActive()
        XCTAssertEqual(runs, 1)
    }

    func testRunsOnlyOnceWhenTimeoutThenActivation() {
        start(active: false)
        scheduled[0].work()
        becomeActive()
        XCTAssertEqual(runs, 1)
    }

    func testIgnoresOtherNotifications() {
        start(active: false)
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        XCTAssertEqual(runs, 0)
    }
}
