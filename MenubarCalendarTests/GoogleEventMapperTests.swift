import XCTest
@testable import MenubarCalendar

final class GoogleEventMapperTests: XCTestCase {

    private let warsaw = TimeZone(identifier: "Europe/Warsaw")!

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = warsaw
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private let writable = GoogleCalendarEntry(
        key: "a@x.com/primary-id", accountEmail: "a@x.com", calendarID: "primary-id",
        title: "a@x.com", colorHex: "#039be5", isWritable: true, isSelectedInGoogle: true
    )

    private func timed(_ extra: [String: Any] = [:]) -> [String: Any] {
        var json: [String: Any] = [
            "id": "evt1",
            "status": "confirmed",
            "summary": "Standup",
            "iCalUID": "uid-1@google.com",
            "start": ["dateTime": "2026-10-05T10:00:00+02:00"],
            "end": ["dateTime": "2026-10-05T10:15:00+02:00"],
        ]
        json.merge(extra) { _, new in new }
        return json
    }

    private func map(_ json: [String: Any], calendar: GoogleCalendarEntry? = nil) -> MappedGoogleEvent? {
        GoogleEventMapper.event(from: json, calendar: calendar ?? writable, timeZone: warsaw)
    }

    // MARK: Times

    func testTimedEventWithOffset() throws {
        let mapped = try XCTUnwrap(map(timed()))
        XCTAssertEqual(mapped.event.startDate, date(2026, 10, 5, 10, 0))
        XCTAssertEqual(mapped.event.endDate, date(2026, 10, 5, 10, 15))
        XCTAssertFalse(mapped.event.isAllDay)
        XCTAssertEqual(mapped.event.identifier, "a@x.com/primary-id/evt1")
        XCTAssertEqual(mapped.event.calendarIdentifier, "a@x.com/primary-id")
        XCTAssertEqual(mapped.event.accountEmail, "a@x.com")
        XCTAssertEqual(mapped.fetchedVia, "a@x.com")
        XCTAssertEqual(mapped.event.iCalUID, "uid-1@google.com")
        XCTAssertEqual(mapped.calendarID, "primary-id")
        XCTAssertEqual(mapped.eventID, "evt1")
        XCTAssertFalse(mapped.event.isEditable)
    }

    func testUTCDateTime() throws {
        let mapped = try XCTUnwrap(map(timed([
            "start": ["dateTime": "2026-10-05T08:00:00Z"],
            "end": ["dateTime": "2026-10-05T08:30:00.000Z"],
        ])))
        XCTAssertEqual(mapped.event.startDate, date(2026, 10, 5, 10, 0))
        XCTAssertEqual(mapped.event.endDate, date(2026, 10, 5, 10, 30))
    }

    func testMultiDayAllDayKeepsGooglesExclusiveEnd() throws {
        let mapped = try XCTUnwrap(map(timed([
            "start": ["date": "2026-10-05"], "end": ["date": "2026-10-07"],
        ])))
        XCTAssertTrue(mapped.event.isAllDay)
        XCTAssertEqual(mapped.event.startDate, date(2026, 10, 5))
        XCTAssertEqual(mapped.event.endDate, date(2026, 10, 7))
    }

    // Review Focus 1: DST ends in Warsaw on 2026-10-25 — that day is 25 h long.
    func testAllDayOnDSTChangeDayIsLocalMidnightToMidnight() throws {
        let mapped = try XCTUnwrap(map(timed([
            "start": ["date": "2026-10-25"], "end": ["date": "2026-10-26"],
        ])))
        XCTAssertEqual(mapped.event.startDate, date(2026, 10, 25))
        XCTAssertEqual(mapped.event.endDate, date(2026, 10, 26))
        XCTAssertEqual(mapped.event.endDate.timeIntervalSince(mapped.event.startDate), 25 * 3600)
    }

    func testMissingTimesIsNil() {
        XCTAssertNil(map(["id": "x", "summary": "Broken"]))
    }

    // MARK: Status and attendees

    func testCancelledIsNil() {
        XCTAssertNil(map(timed(["status": "cancelled"])))
    }

    func testSelfDeclinedIsNil() {
        XCTAssertNil(map(timed(["attendees": [
            ["email": "a@x.com", "self": true, "responseStatus": "declined"],
        ]])))
    }

    func testSomeoneElseDecliningIsKept() throws {
        let mapped = try XCTUnwrap(map(timed(["attendees": [
            ["email": "a@x.com", "self": true, "responseStatus": "accepted"],
            ["email": "b@x.com", "responseStatus": "declined"],
        ]])))
        XCTAssertTrue(mapped.hasSelfAttendee)
        XCTAssertTrue(mapped.event.canDecline)
    }

    func testCannotDeclineWithoutSelfAttendee() throws {
        let mapped = try XCTUnwrap(map(timed()))
        XCTAssertFalse(mapped.hasSelfAttendee)
        XCTAssertFalse(mapped.event.canDecline)
    }

    func testCannotDeclineOnReadOnlyCalendar() throws {
        let readOnly = GoogleCalendarEntry(
            key: "a@x.com/team", accountEmail: "a@x.com", calendarID: "team",
            title: "Team", colorHex: nil, isWritable: false, isSelectedInGoogle: true
        )
        let mapped = try XCTUnwrap(map(timed(["attendees": [["email": "a@x.com", "self": true]]]),
                                       calendar: readOnly))
        XCTAssertFalse(mapped.event.canDecline)
    }

    func testMissingTitleIsEmpty() throws {
        var json = timed()
        json["summary"] = nil
        XCTAssertEqual(try XCTUnwrap(map(json)).event.title, "")
    }

    // MARK: Owning account

    // A personal calendar shared into another account: the meeting belongs to
    // the calendar's owner (Chrome profile, `authuser=`), but API calls must go
    // through the account that fetched it.
    func testSharedPersonalCalendarIsOwnedByTheSelfAttendee() throws {
        let shared = GoogleCalendarEntry(
            key: "mail@x.com/radek@tonik.com", accountEmail: "mail@x.com", calendarID: "radek@tonik.com",
            title: "radek@tonik.com", colorHex: nil, isWritable: true, isSelectedInGoogle: true
        )
        let mapped = try XCTUnwrap(map(timed(["attendees": [
            ["email": "radek@tonik.com", "self": true, "responseStatus": "accepted"],
            ["email": "boss@tonik.com", "organizer": true],
        ]]), calendar: shared))
        XCTAssertEqual(mapped.event.accountEmail, "radek@tonik.com")
        XCTAssertEqual(mapped.fetchedVia, "mail@x.com")
        XCTAssertEqual(mapped.event.identifier, "mail@x.com/radek@tonik.com/evt1")
    }

    func testSharedPersonalCalendarWithoutSelfAttendeeIsOwnedByTheCalendar() throws {
        let shared = GoogleCalendarEntry(
            key: "mail@x.com/radek@tonik.com", accountEmail: "mail@x.com", calendarID: "radek@tonik.com",
            title: "radek@tonik.com", colorHex: nil, isWritable: false, isSelectedInGoogle: true
        )
        let mapped = try XCTUnwrap(map(timed(), calendar: shared))
        XCTAssertEqual(mapped.event.accountEmail, "radek@tonik.com")
        XCTAssertEqual(mapped.fetchedVia, "mail@x.com")
    }

    func testGroupCalendarWithoutSelfAttendeeIsOwnedByTheFetchingAccount() throws {
        let group = GoogleCalendarEntry(
            key: "a@x.com/team@group.calendar.google.com", accountEmail: "a@x.com",
            calendarID: "team@group.calendar.google.com",
            title: "Team", colorHex: nil, isWritable: false, isSelectedInGoogle: true
        )
        let mapped = try XCTUnwrap(map(timed(), calendar: group))
        XCTAssertEqual(mapped.event.accountEmail, "a@x.com")
        XCTAssertEqual(mapped.fetchedVia, "a@x.com")
    }

    func testGroupCalendarAsSelfAttendeeIsOwnedByTheFetchingAccount() throws {
        let group = GoogleCalendarEntry(
            key: "a@x.com/team@group.calendar.google.com", accountEmail: "a@x.com",
            calendarID: "team@group.calendar.google.com",
            title: "Team", colorHex: nil, isWritable: true, isSelectedInGoogle: true
        )
        let mapped = try XCTUnwrap(map(timed(["attendees": [
            ["email": "team@group.calendar.google.com", "self": true, "responseStatus": "accepted"],
        ]]), calendar: group))
        XCTAssertEqual(mapped.event.accountEmail, "a@x.com")
    }

    func testHTMLLinkIsTheWebURL() throws {
        let mapped = try XCTUnwrap(map(timed([
            "htmlLink": "https://www.google.com/calendar/event?eid=abc123",
        ])))
        XCTAssertEqual(mapped.event.webURL, URL(string: "https://www.google.com/calendar/event?eid=abc123"))
        XCTAssertNil(try XCTUnwrap(map(timed())).event.webURL)
    }

    // MARK: Meeting links

    func testHangoutLinkWins() throws {
        let mapped = try XCTUnwrap(map(timed([
            "hangoutLink": "https://meet.google.com/abc-defg-hij",
            "conferenceData": ["entryPoints": [["entryPointType": "video", "uri": "https://zoom.us/j/1"]]],
        ])))
        XCTAssertEqual(mapped.event.url, URL(string: "https://meet.google.com/abc-defg-hij"))
    }

    func testConferenceVideoEntryPoint() throws {
        let mapped = try XCTUnwrap(map(timed([
            "conferenceData": ["entryPoints": [
                ["entryPointType": "phone", "uri": "tel:+48-123"],
                ["entryPointType": "video", "uri": "https://tonik.zoom.us/j/999"],
            ]],
        ])))
        XCTAssertEqual(mapped.event.url, URL(string: "https://tonik.zoom.us/j/999"))
    }

    // Review Focus 3: a link only inside the HTML description is still joinable.
    func testLinkOnlyInHTMLDescriptionIsJoinable() throws {
        let mapped = try XCTUnwrap(map(timed([
            "description": "Agenda<br><a href=\"https://tonik.zoom.us/j/123456789\">Join Zoom</a>",
            "location": "Office",
        ])))
        XCTAssertNil(mapped.event.url)
        XCTAssertEqual(mapped.event.location, "Office")
        XCTAssertEqual(EventLinkExtractor.meetingURL(for: mapped.event)?.absoluteString,
                       "https://tonik.zoom.us/j/123456789")
    }

    // MARK: Calendars

    func testCalendarEntry() throws {
        let entry = try XCTUnwrap(GoogleEventMapper.calendar(from: [
            "id": "team@group.calendar.google.com", "summary": "Team", "summaryOverride": "My team",
            "backgroundColor": "#9fe1e7", "accessRole": "reader", "selected": true,
        ], accountEmail: "a@x.com"))
        XCTAssertEqual(entry.key, "a@x.com/team@group.calendar.google.com")
        XCTAssertEqual(entry.title, "My team")
        XCTAssertEqual(entry.colorHex, "#9fe1e7")
        XCTAssertFalse(entry.isWritable)
        XCTAssertTrue(entry.isSelectedInGoogle)
    }

    func testSecondaryCalendarWithoutSelectedIsUnselected() throws {
        let entry = try XCTUnwrap(GoogleEventMapper.calendar(
            from: ["id": "holidays", "summary": "Holidays", "accessRole": "reader"], accountEmail: "a@x.com"))
        XCTAssertFalse(entry.isSelectedInGoogle)
    }

    // Review Focus 4: a primary calendar without `selected` still shows by default.
    func testPrimaryCalendarWithoutSelectedIsSelected() throws {
        let entry = try XCTUnwrap(GoogleEventMapper.calendar(
            from: ["id": "a@x.com", "summary": "a@x.com", "accessRole": "owner", "primary": true],
            accountEmail: "a@x.com"))
        XCTAssertTrue(entry.isSelectedInGoogle)
        XCTAssertTrue(entry.isWritable)
    }

    // MARK: Dedupe

    /// A copy fetched through `account` from calendar `calendarID`, owned by
    /// `owner` (defaults to the fetching account).
    private func copy(
        account: String, owner: String? = nil, calendarID: String = "cal",
        uid: String?, start: Date, isAttendee: Bool
    ) -> MappedGoogleEvent {
        MappedGoogleEvent(
            event: CalendarEvent(
                identifier: "\(account)/\(calendarID)/\(uid ?? "x")", title: "Sync", startDate: start,
                endDate: start.addingTimeInterval(1800), isAllDay: false,
                calendarIdentifier: "\(account)/\(calendarID)", calendarTitle: calendarID,
                accountEmail: owner ?? account, iCalUID: uid
            ),
            calendarID: calendarID, eventID: uid ?? "x", fetchedVia: account, hasSelfAttendee: isAttendee
        )
    }

    func testDedupePrefersTheCopyWhereTheAccountIsInvited() {
        let start = date(2026, 10, 5, 12)
        let result = GoogleEventMapper.dedupe([
            copy(account: "work@x.com", uid: "u1", start: start, isAttendee: false),
            copy(account: "home@x.com", uid: "u1", start: start, isAttendee: true),
        ])
        XCTAssertEqual(result.map(\.event.accountEmail), ["home@x.com"])
    }

    func testDedupeKeepsTheFirstAccountWhenNeitherIsInvited() {
        let start = date(2026, 10, 5, 12)
        let result = GoogleEventMapper.dedupe([
            copy(account: "work@x.com", uid: "u1", start: start, isAttendee: false),
            copy(account: "home@x.com", uid: "u1", start: start, isAttendee: false),
        ])
        XCTAssertEqual(result.map(\.event.accountEmail), ["work@x.com"])
    }

    // Both copies list radek@tonik.com as `self`: the one fetched through
    // radek@tonik.com itself wins over the one seen via a calendar shared into
    // mail@x.com, whichever account was connected first.
    func testDedupePrefersTheCopyFetchedByTheOwningAccount() {
        let start = date(2026, 10, 5, 12)
        let result = GoogleEventMapper.dedupe([
            copy(account: "mail@x.com", owner: "radek@tonik.com", calendarID: "radek@tonik.com",
                 uid: "u1", start: start, isAttendee: true),
            copy(account: "radek@tonik.com", calendarID: "radek@tonik.com",
                 uid: "u1", start: start, isAttendee: true),
        ])
        XCTAssertEqual(result.map(\.fetchedVia), ["radek@tonik.com"])
        XCTAssertEqual(result.map(\.event.accountEmail), ["radek@tonik.com"])
    }

    func testDedupeKeepsSeparateOccurrencesAndEventsWithoutUID() {
        let result = GoogleEventMapper.dedupe([
            copy(account: "a@x.com", uid: "u1", start: date(2026, 10, 5, 12), isAttendee: true),
            copy(account: "a@x.com", uid: "u1", start: date(2026, 10, 6, 12), isAttendee: true),
            copy(account: "a@x.com", uid: nil, start: date(2026, 10, 5, 12), isAttendee: true),
            copy(account: "b@x.com", uid: nil, start: date(2026, 10, 5, 12), isAttendee: true),
        ])
        XCTAssertEqual(result.count, 4)
    }

    func testRFC3339IsUTC() {
        XCTAssertEqual(GoogleEventMapper.rfc3339(date(2026, 10, 5, 10)), "2026-10-05T08:00:00Z")
    }
}
