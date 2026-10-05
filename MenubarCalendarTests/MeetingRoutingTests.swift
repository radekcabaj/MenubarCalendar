import XCTest
@testable import MenubarCalendar

final class MeetingRoutingTests: XCTestCase {
    private func route(
        owner: String?, fallback: String?, connected: [String] = [], withProfile: Set<String> = []
    ) -> String? {
        CalendarViewModel.routingEmail(
            owner: owner, fallback: fallback, connected: connected,
            hasProfile: { withProfile.contains($0) }
        )
    }

    func testConnectedOwnerWinsOverFallback() {
        XCTAssertEqual(
            route(owner: "Me@Tonik.com", fallback: "me@gmail.com", connected: ["me@tonik.com"]),
            "Me@Tonik.com"
        )
    }

    func testOwnerWithProfileWinsOverFallback() {
        XCTAssertEqual(
            route(owner: "me@work.com", fallback: "me@tonik.com", withProfile: ["me@work.com"]),
            "me@work.com"
        )
    }

    func testUnknownOwnerUsesFallback() {
        XCTAssertEqual(
            route(owner: "boss@tonik.com", fallback: "me@tonik.com", connected: ["me@tonik.com"]),
            "me@tonik.com"
        )
    }

    func testUnknownOwnerWithoutFallbackKeepsOwner() {
        XCTAssertEqual(route(owner: "boss@tonik.com", fallback: nil), "boss@tonik.com")
    }

    func testNoOwnerUsesFallback() {
        XCTAssertEqual(route(owner: nil, fallback: "me@tonik.com"), "me@tonik.com")
    }

    func testNothingKnownIsNil() {
        XCTAssertNil(route(owner: nil, fallback: nil))
    }
}
