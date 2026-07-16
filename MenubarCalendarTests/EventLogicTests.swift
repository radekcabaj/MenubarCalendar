import XCTest
@testable import MenubarCalendar

/// Unit tests for the pure selection / formatting logic (PRD §3.1, §3.4, §4).
final class EventLogicTests: XCTestCase {

    // A deterministic Polish calendar in a fixed time zone.
    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "pl_PL")
        cal.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        return cal
    }()

    /// Reference "now": Tuesday 2026-07-14, 10:00.
    private lazy var now: Date = date(2026, 7, 14, 10, 0)

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
        return calendar.date(from: c)!
    }

    private func event(
        _ title: String,
        start: Date,
        end: Date? = nil,
        allDay: Bool = false,
        id: String? = nil
    ) -> CalendarEvent {
        CalendarEvent(
            identifier: id ?? title,
            title: title,
            startDate: start,
            endDate: end ?? start.addingTimeInterval(3600),
            isAllDay: allDay,
            calendarIdentifier: "cal",
            calendarTitle: "Praca",
            url: nil,
            location: nil,
            notes: nil
        )
    }

    // MARK: - Countdown

    func testCountdownUnderAnHour() {
        XCTAssertEqual(EventLogic.countdownString(from: now, to: now.addingTimeInterval(27 * 60)), "in 27m")
        XCTAssertEqual(EventLogic.countdownString(from: now, to: now.addingTimeInterval(59 * 60)), "in 59m")
        XCTAssertEqual(EventLogic.countdownString(from: now, to: now), "in 0m")
    }

    func testCountdownOverAnHour() {
        XCTAssertEqual(EventLogic.countdownString(from: now, to: now.addingTimeInterval(135 * 60)), "in 2h 15m")
        XCTAssertEqual(EventLogic.countdownString(from: now, to: now.addingTimeInterval(120 * 60)), "in 2h")
    }

    func testCountdownFloorsSeconds() {
        // 27 min 40 s → "in 27m"
        XCTAssertEqual(EventLogic.countdownString(from: now, to: now.addingTimeInterval(27 * 60 + 40)), "in 27m")
    }

    // MARK: - Titles

    func testTruncatedTitle() {
        XCTAssertEqual(EventLogic.truncatedTitle("Standup"), "Standup")
        XCTAssertEqual(EventLogic.truncatedTitle(String(repeating: "x", count: 20)), String(repeating: "x", count: 20))
        XCTAssertEqual(EventLogic.truncatedTitle(String(repeating: "x", count: 25)), String(repeating: "x", count: 20) + "…")
        XCTAssertEqual(EventLogic.truncatedTitle("   "), "(No title)")
    }

    // MARK: - Day / time labels

    func testSectionHeaderTitle() {
        XCTAssertEqual(EventLogic.sectionHeaderTitle(for: date(2026, 7, 14, 15, 0), now: now, calendar: calendar), "Today")
        XCTAssertEqual(EventLogic.sectionHeaderTitle(for: date(2026, 7, 15, 9, 0), now: now, calendar: calendar), "Tomorrow")
        // 2026-07-17 is a Friday.
        XCTAssertEqual(EventLogic.sectionHeaderTitle(for: date(2026, 7, 17, 9, 0), now: now, calendar: calendar), "Friday")
    }

    func testDateLabel() {
        XCTAssertEqual(EventLogic.dateLabel(for: date(2026, 7, 14, 0, 0), calendar: calendar), "Jul 14")
        XCTAssertEqual(EventLogic.dateLabel(for: date(2026, 7, 16, 0, 0), calendar: calendar), "Jul 16")
    }

    func testTimeString() {
        XCTAssertEqual(EventLogic.timeString(for: date(2026, 7, 14, 14, 30), calendar: calendar), "14:30")
        XCTAssertEqual(EventLogic.timeString(for: date(2026, 7, 14, 9, 5), calendar: calendar), "09:05")
    }

    // MARK: - Menu-bar title

    func testMenuBarPrefersTimedEventSameDay() {
        // Timed today at 10:27 (in 27m) plus an all-day today → timed wins.
        let timed = event("Standup", start: date(2026, 7, 14, 10, 27))
        let allDay = event("Urlop", start: date(2026, 7, 14, 0, 0), end: date(2026, 7, 14, 23, 59), allDay: true)
        let title = EventLogic.menuBarTitle([allDay, timed], now: now, showAllDay: true, calendar: calendar)
        XCTAssertEqual(title, "Standup · in 27m")
    }

    func testMenuBarTodayAllDayWhenNoTimedToday() {
        let allDay = event("Urlop", start: date(2026, 7, 14, 0, 0), end: date(2026, 7, 14, 23, 59), allDay: true)
        let title = EventLogic.menuBarTitle([allDay], now: now, showAllDay: true, calendar: calendar)
        XCTAssertEqual(title, "Urlop · (today)")
    }

    func testMenuBarNearestDayWins_TodayAllDayOverTomorrowTimed() {
        // All-day today should beat a timed event tomorrow (nearest-day rule).
        let todayAllDay = event("Urlop", start: date(2026, 7, 14, 0, 0), end: date(2026, 7, 14, 23, 59), allDay: true)
        let tomorrowTimed = event("Spotkanie", start: date(2026, 7, 15, 9, 0))
        let title = EventLogic.menuBarTitle([tomorrowTimed, todayAllDay], now: now, showAllDay: true, calendar: calendar)
        XCTAssertEqual(title, "Urlop · (today)")
    }

    func testMenuBarFutureAllDayUsesWeekday() {
        let fridayAllDay = event("Konferencja", start: date(2026, 7, 17, 0, 0), end: date(2026, 7, 17, 23, 59), allDay: true)
        let title = EventLogic.menuBarTitle([fridayAllDay], now: now, showAllDay: true, calendar: calendar)
        XCTAssertEqual(title, "Konferencja · (Fri)")
    }

    func testMenuBarNoEvents() {
        XCTAssertEqual(EventLogic.menuBarTitle([], now: now, showAllDay: true, calendar: calendar), "No events")
    }

    // MARK: - In-progress meeting

    func testMenuBarShowsRemainingForInProgressMeeting() {
        // Started 10 min ago, ends in 15 min.
        let ongoing = event("Standup", start: now.addingTimeInterval(-10 * 60), end: now.addingTimeInterval(15 * 60))
        XCTAssertEqual(
            EventLogic.menuBarTitle([ongoing], now: now, showAllDay: true, calendar: calendar),
            "Standup · 15m left"
        )
    }

    func testMenuBarRemainingOverAnHour() {
        let ongoing = event("Warsztat", start: now.addingTimeInterval(-5 * 60), end: now.addingTimeInterval(75 * 60))
        XCTAssertEqual(
            EventLogic.menuBarTitle([ongoing], now: now, showAllDay: true, calendar: calendar),
            "Warsztat · 1h 15m left"
        )
    }

    func testInProgressBeatsUpcoming() {
        // A meeting running now should be shown instead of the next one.
        let ongoing = event("Teraz", start: now.addingTimeInterval(-20 * 60), end: now.addingTimeInterval(10 * 60))
        let soon = event("Potem", start: now.addingTimeInterval(5 * 60))
        XCTAssertEqual(
            EventLogic.menuBarTitle([soon, ongoing], now: now, showAllDay: true, calendar: calendar),
            "Teraz · 10m left"
        )
    }

    func testInProgressPicksEndingSoonest() {
        let endsLater = event("Długie", start: now.addingTimeInterval(-30 * 60), end: now.addingTimeInterval(40 * 60), id: "a")
        let endsSooner = event("Krótkie", start: now.addingTimeInterval(-10 * 60), end: now.addingTimeInterval(12 * 60), id: "b")
        XCTAssertEqual(
            EventLogic.menuBarTitle([endsLater, endsSooner], now: now, showAllDay: true, calendar: calendar),
            "Krótkie · 12m left"
        )
    }

    func testEndedMeetingIsNotShown() {
        // Ended 5 min ago → excluded; the upcoming one is shown instead.
        let ended = event("Było", start: now.addingTimeInterval(-60 * 60), end: now.addingTimeInterval(-5 * 60), id: "a")
        let next = event("Będzie", start: now.addingTimeInterval(40 * 60), id: "b")
        XCTAssertEqual(
            EventLogic.menuBarTitle([ended, next], now: now, showAllDay: true, calendar: calendar),
            "Będzie · in 40m"
        )
    }

    func testMeetingWithUnderAMinuteLeftMovesToNextEvent() {
        // 30s left → no longer shown as ongoing; the next event is shown instead.
        let almostDone = event("Kończy się", start: now.addingTimeInterval(-30 * 60), end: now.addingTimeInterval(30), id: "a")
        let next = event("Następne", start: now.addingTimeInterval(25 * 60), id: "b")
        XCTAssertEqual(
            EventLogic.menuBarTitle([almostDone, next], now: now, showAllDay: true, calendar: calendar),
            "Następne · in 25m"
        )
    }

    func testMeetingWithUnderAMinuteLeftAndNothingNextShowsNoEvents() {
        let almostDone = event("Kończy się", start: now.addingTimeInterval(-30 * 60), end: now.addingTimeInterval(30))
        XCTAssertEqual(
            EventLogic.menuBarTitle([almostDone], now: now, showAllDay: false, calendar: calendar),
            "No events"
        )
    }

    func testMenuBarAllDayHiddenWhenToggleOff() {
        let allDay = event("Urlop", start: date(2026, 7, 14, 0, 0), end: date(2026, 7, 14, 23, 59), allDay: true)
        XCTAssertEqual(EventLogic.menuBarTitle([allDay], now: now, showAllDay: false, calendar: calendar), "No events")
    }

    func testMenuBarIgnoresPastTimedEvents() {
        // "Past" here means it already ended (before now, which is 10:00).
        let past = event("Było", start: date(2026, 7, 14, 8, 0), end: date(2026, 7, 14, 9, 0))
        XCTAssertEqual(EventLogic.menuBarTitle([past], now: now, showAllDay: true, calendar: calendar), "No events")
    }

    // MARK: - Day-grouped list

    func testDaySectionsGroupsThreeDaysAndFiltersToday() {
        // Today (2026-07-14, now = 10:00): one ended, one in progress, one later.
        let endedToday = event("Ended", start: date(2026, 7, 14, 8, 0), end: date(2026, 7, 14, 9, 0), id: "e")
        let inProgress = event("Now", start: date(2026, 7, 14, 9, 30), end: date(2026, 7, 14, 10, 30), id: "n")
        let laterToday = event("Later", start: date(2026, 7, 14, 14, 0), id: "l")
        let tomorrow = event("Tomorrow", start: date(2026, 7, 15, 9, 0), id: "t")
        let dayThree = event("DayThree", start: date(2026, 7, 16, 11, 0), id: "d3")
        let dayFour = event("DayFour", start: date(2026, 7, 17, 9, 0), id: "d4")

        let groups = EventLogic.daySections(
            [dayFour, dayThree, tomorrow, laterToday, inProgress, endedToday],
            now: now, showAllDay: true, calendar: calendar
        )

        XCTAssertEqual(groups.map(\.title), ["Today", "Tomorrow", "Thursday"])
        XCTAssertEqual(groups.map(\.dateLabel), ["Jul 14", "Jul 15", "Jul 16"])
        // Today drops the finished event and sorts by start; day four is out of range.
        XCTAssertEqual(groups[0].events.map(\.title), ["Now", "Later"])
        XCTAssertEqual(groups[1].events.map(\.title), ["Tomorrow"])
        XCTAssertEqual(groups[2].events.map(\.title), ["DayThree"])
    }

    func testDaySectionsOmitsEmptyDays() {
        // Nothing tomorrow → the Tomorrow group is skipped entirely.
        let today = event("Today", start: date(2026, 7, 14, 14, 0), id: "a")
        let dayThree = event("DayThree", start: date(2026, 7, 16, 11, 0), id: "b")
        let groups = EventLogic.daySections([today, dayThree], now: now, showAllDay: true, calendar: calendar)
        XCTAssertEqual(groups.map(\.title), ["Today", "Thursday"])
    }

    func testDaySectionsHidesAllDayWhenToggleOff() {
        let allDay = event("Holiday", start: date(2026, 7, 15, 0, 0), end: date(2026, 7, 16, 0, 0), allDay: true)
        XCTAssertTrue(EventLogic.daySections([allDay], now: now, showAllDay: false, calendar: calendar).isEmpty)
        XCTAssertEqual(
            EventLogic.daySections([allDay], now: now, showAllDay: true, calendar: calendar).map(\.title),
            ["Tomorrow"]
        )
    }

    func testDaySectionsShowsMultiDayAllDayUnderEachDay() {
        // An all-day event spanning today through the third day appears in all three.
        let vacation = event("Vacation", start: date(2026, 7, 14, 0, 0), end: date(2026, 7, 16, 12, 0), allDay: true)
        let groups = EventLogic.daySections([vacation], now: now, showAllDay: true, calendar: calendar)
        XCTAssertEqual(groups.map(\.title), ["Today", "Tomorrow", "Thursday"])
        XCTAssertTrue(groups.allSatisfy { $0.events.map(\.title) == ["Vacation"] })
    }
}
