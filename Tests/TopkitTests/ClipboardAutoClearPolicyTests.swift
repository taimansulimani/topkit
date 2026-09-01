import Foundation
import XCTest
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

final class ClipboardAutoClearPolicyTests: XCTestCase {
    /// Deterministic UTC Gregorian calendar so day/week math doesn't depend on the host locale.
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = mo; comps.day = d; comps.hour = h; comps.minute = mi
        return utc.date(from: comps)!
    }

    private func config(
        enabled: Bool = true,
        mode: ClipboardAutoClearConfig.Mode = .daily,
        intervalValue: Int = 1,
        intervalUnit: ClipboardAutoClearConfig.IntervalUnit = .days,
        hour: Int = 3,
        minute: Int = 0,
        weekday: Int = 2
    ) -> ClipboardAutoClearConfig {
        ClipboardAutoClearConfig(
            enabled: enabled, mode: mode, intervalValue: intervalValue,
            intervalUnit: intervalUnit, hour: hour, minute: minute, weekday: weekday
        )
    }

    func testDisabledNeverClears() {
        let cfg = config(enabled: false, mode: .interval)
        XCTAssertFalse(ClipboardAutoClearPolicy.shouldClear(
            now: date(2026, 1, 1, 12, 0),
            lastClear: date(2020, 1, 1, 0, 0),
            config: cfg, calendar: utc
        ))
    }

    func testNilBaselineNeverClears() {
        // No baseline yet (caller seeds "now" on enable) → never an immediate wipe.
        for mode: ClipboardAutoClearConfig.Mode in [.interval, .daily, .weekly] {
            XCTAssertFalse(ClipboardAutoClearPolicy.shouldClear(
                now: date(2026, 1, 1, 12, 0),
                lastClear: nil,
                config: config(mode: mode), calendar: utc
            ), "mode \(mode) should not clear without a baseline")
        }
    }

    func testIntervalSeconds() {
        XCTAssertEqual(ClipboardAutoClearPolicy.intervalSeconds(config(intervalValue: 2, intervalUnit: .hours)), 7_200)
        XCTAssertEqual(ClipboardAutoClearPolicy.intervalSeconds(config(intervalValue: 3, intervalUnit: .days)), 259_200)
        XCTAssertEqual(ClipboardAutoClearPolicy.intervalSeconds(config(intervalValue: 1, intervalUnit: .weeks)), 604_800)
        // Value clamped to a minimum of 1.
        XCTAssertEqual(ClipboardAutoClearPolicy.intervalSeconds(config(intervalValue: 0, intervalUnit: .hours)), 3_600)
    }

    func testIntervalClearsAfterElapsed() {
        let cfg = config(mode: .interval, intervalValue: 6, intervalUnit: .hours)
        let last = date(2026, 1, 1, 0, 0)
        // 5h elapsed → not yet.
        XCTAssertFalse(ClipboardAutoClearPolicy.shouldClear(now: date(2026, 1, 1, 5, 0), lastClear: last, config: cfg, calendar: utc))
        // 6h elapsed → due.
        XCTAssertTrue(ClipboardAutoClearPolicy.shouldClear(now: date(2026, 1, 1, 6, 0), lastClear: last, config: cfg, calendar: utc))
    }

    func testDailyClearsOncePerDayAfterScheduledTime() {
        let cfg = config(mode: .daily, hour: 3, minute: 0)
        // Baseline set yesterday; now is past today's 03:00 → due.
        XCTAssertTrue(ClipboardAutoClearPolicy.shouldClear(
            now: date(2026, 1, 2, 3, 30),
            lastClear: date(2026, 1, 1, 10, 0),
            config: cfg, calendar: utc
        ))
        // Already cleared after today's 03:00 → not due again today.
        XCTAssertFalse(ClipboardAutoClearPolicy.shouldClear(
            now: date(2026, 1, 2, 9, 0),
            lastClear: date(2026, 1, 2, 3, 5),
            config: cfg, calendar: utc
        ))
        // Before today's 03:00, last cleared yesterday after the time → not due (most recent
        // occurrence is yesterday 03:00, which precedes lastClear).
        XCTAssertFalse(ClipboardAutoClearPolicy.shouldClear(
            now: date(2026, 1, 2, 2, 0),
            lastClear: date(2026, 1, 1, 4, 0),
            config: cfg, calendar: utc
        ))
    }

    func testWeeklyClearsOnConfiguredWeekday() {
        // 2026-01-05 is a Monday (weekday 2 in Gregorian/UTC).
        XCTAssertEqual(utc.component(.weekday, from: date(2026, 1, 5, 12, 0)), 2)
        let cfg = config(mode: .weekly, hour: 3, minute: 0, weekday: 2)

        // Monday after 03:00, last cleared previous week → due.
        XCTAssertTrue(ClipboardAutoClearPolicy.shouldClear(
            now: date(2026, 1, 5, 4, 0),
            lastClear: date(2025, 12, 29, 4, 0),
            config: cfg, calendar: utc
        ))
        // Tuesday, already cleared on Monday → most recent occurrence is Mon 03:00 < lastClear → not due.
        XCTAssertFalse(ClipboardAutoClearPolicy.shouldClear(
            now: date(2026, 1, 6, 12, 0),
            lastClear: date(2026, 1, 5, 3, 1),
            config: cfg, calendar: utc
        ))
    }
}
