import XCTest
@testable import MenubarCalendar

/// Tests for meeting-link extraction from the url / location / notes fields.
final class EventLinkExtractorTests: XCTestCase {

    private func event(url: URL? = nil, location: String? = nil, notes: String? = nil) -> CalendarEvent {
        CalendarEvent(
            identifier: "id",
            title: "T",
            startDate: Date(timeIntervalSince1970: 0),
            endDate: Date(timeIntervalSince1970: 3600),
            isAllDay: false,
            calendarIdentifier: "c",
            calendarTitle: "Cal",
            url: url,
            location: location,
            notes: notes
        )
    }

    func testUsesUrlFieldWhenWeb() {
        let e = event(url: URL(string: "https://meet.google.com/abc-defg-hij"))
        XCTAssertEqual(EventLinkExtractor.meetingURL(for: e)?.absoluteString, "https://meet.google.com/abc-defg-hij")
    }

    func testFindsLinkInNotes() {
        let e = event(notes: "Dołącz tutaj: https://zoom.us/j/123456789 do zobaczenia")
        XCTAssertEqual(EventLinkExtractor.meetingURL(for: e)?.host, "zoom.us")
    }

    func testFindsLinkInLocation() {
        let e = event(location: "https://whereby.com/tonik")
        XCTAssertEqual(EventLinkExtractor.meetingURL(for: e)?.host, "whereby.com")
    }

    func testPrefersMeetingHostOverOtherLink() {
        let e = event(notes: "Agenda: https://example.com/agenda\nCall: https://teams.microsoft.com/l/meetup-join/xyz")
        XCTAssertEqual(EventLinkExtractor.meetingURL(for: e)?.host, "teams.microsoft.com")
    }

    func testIgnoresNonWebUrlField() {
        let e = event(url: URL(string: "message://%3Cguid%3E"), notes: "https://meet.google.com/xyz")
        XCTAssertEqual(EventLinkExtractor.meetingURL(for: e)?.host, "meet.google.com")
    }

    func testFallsBackToFirstWebLink() {
        let e = event(notes: "Docs: https://example.com/doc")
        XCTAssertEqual(EventLinkExtractor.meetingURL(for: e)?.host, "example.com")
    }

    func testNoLinkReturnsNil() {
        let e = event(notes: "Brak linku, tylko notatka.")
        XCTAssertNil(EventLinkExtractor.meetingURL(for: e))
    }

    // MARK: - authuser rewrite

    func testAddsAuthuserToGoogleURL() {
        let url = URL(string: "https://meet.google.com/abc-defg-hij")!
        let out = EventLinkExtractor.accountURL(url, authuserEmail: "radek@tonik.com")
        XCTAssertTrue(out.absoluteString.contains("authuser=radek@tonik.com")
                      || out.absoluteString.contains("authuser=radek%40tonik.com"))
        XCTAssertEqual(out.host, "meet.google.com")
    }

    func testReplacesExistingAuthuser() {
        let url = URL(string: "https://calendar.google.com/event?authuser=0&eid=x")!
        let out = EventLinkExtractor.accountURL(url, authuserEmail: "radek@tonik.com")
        let items = URLComponents(url: out, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.filter { $0.name == "authuser" }.count, 1)
        XCTAssertEqual(items.first { $0.name == "authuser" }?.value, "radek@tonik.com")
    }

    func testLeavesNonGoogleURLUnchanged() {
        let url = URL(string: "https://zoom.us/j/123")!
        XCTAssertEqual(EventLinkExtractor.accountURL(url, authuserEmail: "radek@tonik.com"), url)
    }
}
