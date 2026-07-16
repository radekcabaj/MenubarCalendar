import XCTest
@testable import MenubarCalendar

/// Tests for Chrome profile resolution (primary + secondary accounts) and the
/// `authuser` rewrite for Google links.
final class ChromeProfileResolverTests: XCTestCase {

    private let localState = Data("""
    {"profile":{"info_cache":{
      "Default":{"user_name":"mail@radekcabaj.com","name":"Personal"},
      "Profile 1":{"user_name":"cabajradek@gmail.com","name":"Gmail"}
    }}}
    """.utf8)

    private let defaultPrefs = Data("""
    {"account_info":[
      {"email":"mail@radekcabaj.com"},
      {"email":"radek@tonik.com"},
      {"email":"radek@alaffia.io"}
    ]}
    """.utf8)

    // Mirrors the real setup: tonik is a *secondary* account in "Default" only.
    private var profiles: [ChromeProfile] {
        [
            ChromeProfile(directory: "Default", primaryEmail: "mail@radekcabaj.com",
                          accountEmails: ["mail@radekcabaj.com", "radek@tonik.com", "radek@alaffia.io"]),
            ChromeProfile(directory: "Profile 1", primaryEmail: "cabajradek@gmail.com",
                          accountEmails: ["cabajradek@gmail.com", "mail@radekcabaj.com"]),
        ]
    }

    // MARK: - Parsing

    func testPrimaryEmailsFromLocalState() {
        let map = ChromeProfileResolver.primaryEmails(fromLocalState: localState)
        XCTAssertEqual(map["Default"], "mail@radekcabaj.com")
        XCTAssertEqual(map["Profile 1"], "cabajradek@gmail.com")
    }

    func testAccountEmailsFromPreferences() {
        let emails = ChromeProfileResolver.accountEmails(fromPreferences: defaultPrefs)
        XCTAssertEqual(emails, ["mail@radekcabaj.com", "radek@tonik.com", "radek@alaffia.io"])
    }

    func testMalformedPreferencesReturnsEmpty() {
        XCTAssertTrue(ChromeProfileResolver.accountEmails(fromPreferences: Data("x".utf8)).isEmpty)
    }

    // MARK: - Resolution

    func testResolvesSecondaryAccountToItsProfile() {
        XCTAssertEqual(
            ChromeProfileResolver.resolveProfileDirectory(forEmail: "radek@tonik.com", profiles: profiles),
            "Default"
        )
    }

    func testPrimaryAccountWins() {
        // Present as primary in "Profile 1" and secondary in "Default" → primary wins.
        XCTAssertEqual(
            ChromeProfileResolver.resolveProfileDirectory(forEmail: "cabajradek@gmail.com", profiles: profiles),
            "Profile 1"
        )
    }

    func testResolutionIsCaseInsensitive() {
        XCTAssertEqual(
            ChromeProfileResolver.resolveProfileDirectory(forEmail: "RADEK@Tonik.com", profiles: profiles),
            "Default"
        )
    }

    func testUnknownEmailReturnsNil() {
        XCTAssertNil(
            ChromeProfileResolver.resolveProfileDirectory(forEmail: "nieznany@x.com", profiles: profiles)
        )
    }

    // MARK: - authuser rewrite

    func testAddsAuthuserToGoogleURL() {
        let url = URL(string: "https://meet.google.com/abc-defg-hij")!
        let out = ChromeProfileResolver.googleURL(url, authuserEmail: "radek@tonik.com")
        XCTAssertTrue(out.absoluteString.contains("authuser=radek@tonik.com")
                      || out.absoluteString.contains("authuser=radek%40tonik.com"))
        XCTAssertEqual(out.host, "meet.google.com")
    }

    func testReplacesExistingAuthuser() {
        let url = URL(string: "https://calendar.google.com/event?authuser=0&eid=x")!
        let out = ChromeProfileResolver.googleURL(url, authuserEmail: "radek@tonik.com")
        let items = URLComponents(url: out, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.filter { $0.name == "authuser" }.count, 1)
        XCTAssertEqual(items.first { $0.name == "authuser" }?.value, "radek@tonik.com")
    }

    func testLeavesNonGoogleURLUnchanged() {
        let url = URL(string: "https://zoom.us/j/123")!
        XCTAssertEqual(ChromeProfileResolver.googleURL(url, authuserEmail: "radek@tonik.com"), url)
    }
}
