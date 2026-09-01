import Foundation

/// User-configurable schedule for automatically clearing clipboard history.
///
/// Pure value type so the "should we clear now?" decision is fully unit-testable without
/// timers, `UserDefaults`, or wall-clock dependencies.
struct ClipboardAutoClearConfig: Equatable {
    enum Mode: String { case interval, daily, weekly }
    enum IntervalUnit: String { case hours, days, weeks }

    var enabled: Bool
    /// `interval`: every N units. `daily`: every day at `hour:minute`.
    /// `weekly`: every week on `weekday` at `hour:minute`.
    var mode: Mode
    var intervalValue: Int
    var intervalUnit: IntervalUnit
    var hour: Int        // 0...23
    var minute: Int      // 0...59
    var weekday: Int     // 1...7 (Calendar convention: 1 = Sunday, 2 = Monday, …)

    static let `default` = ClipboardAutoClearConfig(
        enabled: false,
        mode: .daily,
        intervalValue: 1,
        intervalUnit: .days,
        hour: 3,
        minute: 0,
        weekday: 2
    )
}

/// Stateless scheduling logic. Given the current time and when history was last auto-cleared,
/// decides whether another clear is due.
enum ClipboardAutoClearPolicy {
    /// Seconds represented by `intervalValue` of `intervalUnit` (value clamped to >= 1).
    static func intervalSeconds(_ config: ClipboardAutoClearConfig) -> TimeInterval {
        let unitSeconds: TimeInterval
        switch config.intervalUnit {
        case .hours: unitSeconds = 3_600
        case .days:  unitSeconds = 86_400
        case .weeks: unitSeconds = 604_800
        }
        return TimeInterval(max(1, config.intervalValue)) * unitSeconds
    }

    /// The most recent scheduled clock time at or before `now` for `daily`/`weekly` modes.
    /// Returns `nil` for `interval` mode (which is measured from the last clear instead) or
    /// when no valid occurrence can be computed. Looking at the most recent *past* occurrence
    /// (rather than the next future one) means a run missed while the app was closed collapses
    /// into a single catch-up clear on next launch.
    static func mostRecentOccurrence(
        at now: Date,
        config: ClipboardAutoClearConfig,
        calendar: Calendar
    ) -> Date? {
        switch config.mode {
        case .interval:
            return nil
        case .daily:
            guard let todays = calendar.date(
                bySettingHour: config.hour, minute: config.minute, second: 0, of: now
            ) else { return nil }
            return todays <= now ? todays : calendar.date(byAdding: .day, value: -1, to: todays)
        case .weekly:
            guard let todays = calendar.date(
                bySettingHour: config.hour, minute: config.minute, second: 0, of: now
            ) else { return nil }
            // Step back up to 7 days to the configured weekday at hour:minute, not after `now`.
            for daysBack in 0...7 {
                guard let candidate = calendar.date(byAdding: .day, value: -daysBack, to: todays) else { continue }
                if calendar.component(.weekday, from: candidate) == config.weekday, candidate <= now {
                    return candidate
                }
            }
            return nil
        }
    }

    /// Whether history is due to be auto-cleared.
    ///
    /// `lastClear` is when history was last auto-cleared (or the baseline set when the schedule
    /// was enabled). It must be non-nil for a clear to fire — the caller seeds a baseline of
    /// "now" on enable so toggling the feature on never wipes existing history immediately.
    static func shouldClear(
        now: Date,
        lastClear: Date?,
        config: ClipboardAutoClearConfig,
        calendar: Calendar = .current
    ) -> Bool {
        guard config.enabled, let lastClear else { return false }

        switch config.mode {
        case .interval:
            return now.timeIntervalSince(lastClear) >= intervalSeconds(config)
        case .daily, .weekly:
            guard let occurrence = mostRecentOccurrence(at: now, config: config, calendar: calendar) else {
                return false
            }
            return lastClear < occurrence
        }
    }
}
