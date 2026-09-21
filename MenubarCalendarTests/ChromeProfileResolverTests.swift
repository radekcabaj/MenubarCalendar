import XCTest
@testable import MenubarCalendar

/// Tests for Chrome profile resolution: primary + secondary accounts, and the
/// per-account overrides pinned in Settings. The `authuser` rewrite for Google
/// links is tested in `EventLinkExtractorTests`.
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
            ChromeProfile(directory: "Default", name: "radekcabaj.com", primaryEmail: "mail@radekcabaj.com",
                          accountEmails: ["mail@radekcabaj.com", "radek@tonik.com", "radek@alaffia.io"]),
            ChromeProfile(directory: "Profile 1", name: "Radek", primaryEmail: "cabajradek@gmail.com",
                          accountEmails: ["cabajradek@gmail.com", "mail@radekcabaj.com"]),
        ]
    }

    // MARK: - Parsing

    func testPrimaryEmailsFromLocalState() {
        let map = ChromeProfileResolver.primaryEmails(fromLocalState: localState)
        XCTAssertEqual(map["Default"], "mail@radekcabaj.com")
        XCTAssertEqual(map["Profile 1"], "cabajradek@gmail.com")
    }

    func testDisplayNamesFromLocalState() {
        let map = ChromeProfileResolver.displayNames(fromLocalState: localState)
        XCTAssertEqual(map["Default"], "Personal")
        XCTAssertEqual(map["Profile 1"], "Gmail")
    }

    func testDisplayNameFallsBackToDirectory() {
        let unnamed = ChromeProfile(directory: "Profile 3", name: nil,
                                    primaryEmail: nil, accountEmails: [])
        XCTAssertEqual(unnamed.displayName, "Profile 3")
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

    // MARK: - Overrides pinned in Settings

    func testOverrideBeatsAutomaticMatch() {
        // tonik auto-resolves to "Default"; pinning sends it to "Profile 1".
        XCTAssertEqual(
            ChromeProfileResolver.resolveProfileDirectory(
                forEmail: "radek@tonik.com",
                profiles: profiles,
                overrides: ["radek@tonik.com": "Profile 1"]
            ),
            "Profile 1"
        )
    }

    func testOverrideMatchIsCaseInsensitive() {
        XCTAssertEqual(
            ChromeProfileResolver.resolveProfileDirectory(
                forEmail: "radek@tonik.com",
                profiles: profiles,
                overrides: ["RADEK@Tonik.com": "Profile 1"]
            ),
            "Profile 1"
        )
    }

    func testOverrideForAnotherAccountIsIgnored() {
        XCTAssertEqual(
            ChromeProfileResolver.resolveProfileDirectory(
                forEmail: "radek@tonik.com",
                profiles: profiles,
                overrides: ["someone@else.com": "Profile 1"]
            ),
            "Default"
        )
    }

    func testOverrideToDeletedProfileFallsBackToAutomatic() {
        XCTAssertEqual(
            ChromeProfileResolver.resolveProfileDirectory(
                forEmail: "radek@tonik.com",
                profiles: profiles,
                overrides: ["radek@tonik.com": "Profile 42"]
            ),
            "Default"
        )
    }

    func testOverrideCanResolveAnAccountInNoProfile() {
        // An account Chrome doesn't know about is unresolvable automatically,
        // but a pinned profile still gives it a home.
        XCTAssertEqual(
            ChromeProfileResolver.resolveProfileDirectory(
                forEmail: "nieznany@x.com",
                profiles: profiles,
                overrides: ["nieznany@x.com": "Profile 1"]
            ),
            "Profile 1"
        )
    }

    // MARK: - Command line

    /// The same argv goes to the singleton socket and to a cold launch, so the
    /// profile lands the same way whether Chrome is running or not.
    func testArgumentsPinTheProfile() {
        XCTAssertEqual(
            ChromeProfileResolver.arguments(
                executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                url: URL(string: "https://meet.google.com/abc?authuser=radek@tonik.com")!,
                profileDirectory: "Profile 1"
            ),
            ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
             "--profile-directory=Profile 1",
             "https://meet.google.com/abc?authuser=radek@tonik.com"]
        )
    }

    func testArgumentsWithoutAProfileLeaveChromeToPick() {
        XCTAssertEqual(
            ChromeProfileResolver.arguments(
                executablePath: "/chrome", url: URL(string: "https://example.com")!, profileDirectory: nil
            ),
            ["/chrome", "https://example.com"]
        )
    }
}
