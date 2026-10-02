import SwiftUI
import XCTest
@testable import MenubarCalendar

final class GoogleAPISourceTests: XCTestCase {

    // MARK: PollSchedule

    func testStartsAtTwoMinutes() {
        XCTAssertEqual(PollSchedule().interval, 120)
    }

    func testThrottlingDoublesUpToTenMinutes() {
        var schedule = PollSchedule()
        schedule.recordThrottled()
        XCTAssertEqual(schedule.interval, 240)
        schedule.recordThrottled()
        XCTAssertEqual(schedule.interval, 480)
        schedule.recordThrottled()
        XCTAssertEqual(schedule.interval, 600)
        schedule.recordThrottled()
        XCTAssertEqual(schedule.interval, 600)
    }

    func testSuccessResetsTheInterval() {
        var schedule = PollSchedule()
        schedule.recordThrottled()
        schedule.recordSuccess()
        XCTAssertEqual(schedule.interval, 120)
    }

    func testFreshness() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertFalse(PollSchedule.isFresh(lastSuccess: nil, now: now))
        XCTAssertTrue(PollSchedule.isFresh(lastSuccess: now.addingTimeInterval(-14), now: now))
        XCTAssertFalse(PollSchedule.isFresh(lastSuccess: now.addingTimeInterval(-15), now: now))
    }

    // MARK: Request shape

    func testWindowRunsFromStartOfTodayForSevenDays() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 15, minute: 30))!
        let window = GoogleAPISource.window(now: now, calendar: cal)
        XCTAssertEqual(window.start, cal.date(from: DateComponents(year: 2026, month: 10, day: 2)))
        XCTAssertEqual(window.end, now.addingTimeInterval(7 * 24 * 3600))
    }

    func testEventsURL() throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let url = GoogleAPISource.eventsURL(
            calendarID: "team@group.calendar.google.com",
            window: (start, start.addingTimeInterval(3600))
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "www.googleapis.com")
        XCTAssertEqual(components.percentEncodedPath,
                       "/calendar/v3/calendars/team%40group%2Ecalendar%2Egoogle%2Ecom/events")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["timeMin"], GoogleEventMapper.rfc3339(start))
        XCTAssertEqual(query["timeMax"], GoogleEventMapper.rfc3339(start.addingTimeInterval(3600)))
        XCTAssertEqual(query["singleEvents"], "true")
        XCTAssertEqual(query["orderBy"], "startTime")
        XCTAssertEqual(query["showDeleted"], "false")
        XCTAssertEqual(query["maxResults"], "250")
    }

    // MARK: Color

    func testHexColor() {
        XCTAssertNotNil(Color(hex: "#039be5"))
        XCTAssertNil(Color(hex: nil))
        XCTAssertNil(Color(hex: "039be5"))
        XCTAssertNil(Color(hex: "#zzzzzz"))
    }
}
