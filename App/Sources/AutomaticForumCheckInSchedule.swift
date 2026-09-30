import Foundation

/// Tieba's sign-in day follows Beijing time, independently of the device's calendar and time zone.
struct AutomaticForumCheckInSchedule: Equatable, Sendable {
  static let defaultMinuteOfDay = 9 * 60

  static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
    return calendar
  }()

  let minuteOfDay: Int

  init(minuteOfDay: Int = Self.defaultMinuteOfDay) {
    self.minuteOfDay = (0..<24 * 60).contains(minuteOfDay) ? minuteOfDay : Self.defaultMinuteOfDay
  }

  /// A complete local date avoids treating the same month/day in different years as one run.
  static func dayKey(at date: Date) -> String? {
    guard supports(date) else { return nil }
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    guard let year = components.year, let month = components.month, let day = components.day else {
      return nil
    }
    return String(
      format: "%04d-%02d-%02d",
      locale: Locale(identifier: "en_US_POSIX"),
      year, month, day
    )
  }

  func scheduledDate(on date: Date) -> Date? {
    guard Self.supports(date) else { return nil }
    var components = Self.calendar.dateComponents([.era, .year, .month, .day], from: date)
    components.hour = minuteOfDay / 60
    components.minute = minuteOfDay % 60
    components.second = 0
    return Self.calendar.date(from: components)
  }

  /// Foreground launches after the configured time can catch up on today's run.
  func isDue(at date: Date) -> Bool {
    guard let scheduled = scheduledDate(on: date) else { return false }
    return date >= scheduled
  }

  /// A background request needs a future date even when invoked exactly at today's threshold.
  func nextScheduledDate(after date: Date) -> Date? {
    guard let scheduled = scheduledDate(on: date) else { return nil }
    if scheduled > date { return scheduled }
    guard
      let next = Self.calendar.date(byAdding: .day, value: 1, to: scheduled),
      Self.supports(next)
    else { return nil }
    return next
  }

  // Bound dates before passing them to Calendar: nonfinite or extreme timestamps can otherwise
  // trigger platform-specific calendar behavior. Four-digit AD years also keep journal keys stable.
  private static let supportedDates: Range<Date> = {
    let first = calendar.date(from: DateComponents(era: 1, year: 1, month: 1, day: 1))!
    let end = calendar.date(from: DateComponents(era: 1, year: 10_000, month: 1, day: 1))!
    return first..<end
  }()

  private static func supports(_ date: Date) -> Bool {
    date.timeIntervalSinceReferenceDate.isFinite && supportedDates.contains(date)
  }
}
