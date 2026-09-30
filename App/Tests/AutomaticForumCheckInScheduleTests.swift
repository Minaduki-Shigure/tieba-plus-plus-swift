import Foundation
import XCTest

@testable import TiebaPlusPlus

final class AutomaticForumCheckInScheduleTests: XCTestCase {
  func testDefaultThresholdIsInclusiveAndLateForegroundLaunchCanCatchUp() throws {
    let schedule = AutomaticForumCheckInSchedule()
    let before = try instant("2026-09-30T00:59:59Z")
    let threshold = try instant("2026-09-30T01:00:00Z")
    let late = try instant("2026-09-30T15:59:59Z")

    XCTAssertEqual(schedule.minuteOfDay, 540)
    XCTAssertFalse(schedule.isDue(at: before))
    XCTAssertTrue(schedule.isDue(at: threshold))
    XCTAssertTrue(schedule.isDue(at: late))
    XCTAssertEqual(schedule.scheduledDate(on: before), threshold)
    XCTAssertEqual(schedule.scheduledDate(on: late), threshold)
    XCTAssertEqual(schedule.nextScheduledDate(after: before), threshold)
    XCTAssertEqual(
      schedule.nextScheduledDate(after: threshold), try instant("2026-10-01T01:00:00Z"))
    XCTAssertEqual(
      schedule.nextScheduledDate(after: late), try instant("2026-10-01T01:00:00Z"))
  }

  func testDayKeyChangesAtBeijingMidnightRatherThanUTCMidnight() throws {
    let schedule = AutomaticForumCheckInSchedule()
    let before = try instant("2026-09-30T15:59:59Z")
    let midnight = try instant("2026-09-30T16:00:00Z")

    XCTAssertEqual(AutomaticForumCheckInSchedule.dayKey(at: before), "2026-09-30")
    XCTAssertEqual(AutomaticForumCheckInSchedule.dayKey(at: midnight), "2026-10-01")
    XCTAssertTrue(schedule.isDue(at: before))
    XCTAssertFalse(schedule.isDue(at: midnight))
    XCTAssertEqual(schedule.scheduledDate(on: midnight), try instant("2026-10-01T01:00:00Z"))
    XCTAssertEqual(AutomaticForumCheckInSchedule.calendar.identifier, .gregorian)
    XCTAssertEqual(AutomaticForumCheckInSchedule.calendar.locale?.identifier, "en_US_POSIX")
    XCTAssertEqual(AutomaticForumCheckInSchedule.calendar.timeZone.secondsFromGMT(), 28_800)
  }

  func testNextDateCrossesMonthYearAndGregorianLeapDay() throws {
    let schedule = AutomaticForumCheckInSchedule()
    let cases = [
      ("2026-04-30T01:00:00Z", "2026-05-01T01:00:00Z"),
      ("2026-12-31T01:00:00Z", "2027-01-01T01:00:00Z"),
      ("2028-02-28T01:00:00Z", "2028-02-29T01:00:00Z"),
      ("2028-02-29T01:00:00Z", "2028-03-01T01:00:00Z"),
      ("2100-02-28T01:00:00Z", "2100-03-01T01:00:00Z"),
      ("2000-02-28T01:00:00Z", "2000-02-29T01:00:00Z"),
    ]
    for (input, expected) in cases {
      XCTAssertEqual(
        schedule.nextScheduledDate(after: try instant(input)), try instant(expected), input)
    }
    XCTAssertEqual(
      AutomaticForumCheckInSchedule.dayKey(at: try instant("2026-12-31T16:00:00Z")), "2027-01-01")
    XCTAssertNotEqual(
      AutomaticForumCheckInSchedule.dayKey(at: try instant("2026-09-30T01:00:00Z")),
      AutomaticForumCheckInSchedule.dayKey(at: try instant("2027-09-30T01:00:00Z")))
  }

  func testMinuteConfigurationIncludesMidnightAndLastMinuteButRejectsInvalidValues() throws {
    let midnight = AutomaticForumCheckInSchedule(minuteOfDay: 0)
    let lastMinute = AutomaticForumCheckInSchedule(minuteOfDay: 1_439)
    let today = try instant("2026-09-30T04:00:00Z")

    XCTAssertEqual(midnight.scheduledDate(on: today), try instant("2026-09-29T16:00:00Z"))
    XCTAssertTrue(midnight.isDue(at: today))
    XCTAssertEqual(midnight.nextScheduledDate(after: today), try instant("2026-09-30T16:00:00Z"))
    XCTAssertEqual(lastMinute.scheduledDate(on: today), try instant("2026-09-30T15:59:00Z"))
    XCTAssertFalse(lastMinute.isDue(at: today))
    XCTAssertTrue(lastMinute.isDue(at: try instant("2026-09-30T15:59:00Z")))
    XCTAssertEqual(
      lastMinute.nextScheduledDate(after: try instant("2026-09-30T15:59:00Z")),
      try instant("2026-10-01T15:59:00Z"))

    for invalid in [-1, 1_440, Int.min, Int.max] {
      XCTAssertEqual(AutomaticForumCheckInSchedule(minuteOfDay: invalid), .init(), "\(invalid)")
    }
  }

  func testScheduleUsesBeijingClockForInstantsDescribedInOtherTimeZones() throws {
    let schedule = AutomaticForumCheckInSchedule(minuteOfDay: 540)
    let sameInstants = [
      "2026-09-30T09:00:00+08:00",
      "2026-09-29T18:00:00-07:00",
      "2026-09-30T10:00:00+09:00",
    ]
    for input in sameInstants {
      let date = try instant(input)
      XCTAssertEqual(AutomaticForumCheckInSchedule.dayKey(at: date), "2026-09-30", input)
      XCTAssertEqual(schedule.scheduledDate(on: date), try instant("2026-09-30T01:00:00Z"), input)
      XCTAssertTrue(schedule.isDue(at: date), input)
      XCTAssertEqual(
        schedule.nextScheduledDate(after: date), try instant("2026-10-01T01:00:00Z"), input)
    }
  }

  func testNonfiniteAndUnsupportedDatesFailClosed() throws {
    let schedule = AutomaticForumCheckInSchedule()
    let calendar = AutomaticForumCheckInSchedule.calendar
    let unsupported = [
      Date(timeIntervalSinceReferenceDate: .nan),
      Date(timeIntervalSinceReferenceDate: .infinity),
      Date(timeIntervalSinceReferenceDate: -.infinity),
      Date(timeIntervalSinceReferenceDate: .greatestFiniteMagnitude),
      Date(timeIntervalSinceReferenceDate: -.greatestFiniteMagnitude),
      try XCTUnwrap(calendar.date(from: DateComponents(era: 0, year: 1, month: 12, day: 31))),
      try XCTUnwrap(calendar.date(from: DateComponents(era: 1, year: 10_000, month: 1, day: 1))),
    ]
    for date in unsupported {
      XCTAssertNil(AutomaticForumCheckInSchedule.dayKey(at: date))
      XCTAssertNil(schedule.scheduledDate(on: date))
      XCTAssertNil(schedule.nextScheduledDate(after: date))
      XCTAssertFalse(schedule.isDue(at: date))
    }
  }

  func testSupportedYearsHaveFourDigitKeysAndDoNotScheduleBeyondUpperBound() throws {
    let calendar = AutomaticForumCheckInSchedule.calendar
    let first = try XCTUnwrap(
      calendar.date(from: DateComponents(era: 1, year: 1, month: 1, day: 1)))
    let last = try XCTUnwrap(
      calendar.date(from: DateComponents(era: 1, year: 9_999, month: 12, day: 31, hour: 9)))
    let schedule = AutomaticForumCheckInSchedule()

    XCTAssertEqual(AutomaticForumCheckInSchedule.dayKey(at: first), "0001-01-01")
    XCTAssertNotNil(schedule.scheduledDate(on: first))
    XCTAssertNotNil(schedule.nextScheduledDate(after: first))
    XCTAssertEqual(AutomaticForumCheckInSchedule.dayKey(at: last), "9999-12-31")
    XCTAssertEqual(schedule.scheduledDate(on: last), last)
    XCTAssertTrue(schedule.isDue(at: last))
    XCTAssertNil(schedule.nextScheduledDate(after: last))
  }

  private func instant(_ value: String) throws -> Date {
    try XCTUnwrap(ISO8601DateFormatter().date(from: value), value)
  }
}
