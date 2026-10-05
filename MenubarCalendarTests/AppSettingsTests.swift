import XCTest
@testable import MenubarCalendar

@MainActor
final class AppSettingsTests: XCTestCase {

    /// A throwaway defaults domain per test.
    private func makeDefaults() -> UserDefaults {
        let suite = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testFreshInstallDefaultsToGoogle() {
        let settings = AppSettings(defaults: makeDefaults(), isExistingInstall: false)
        XCTAssertEqual(settings.dataSource, .google)
    }

    func testInstallWithCalendarAccessStaysOnEventKit() {
        let settings = AppSettings(defaults: makeDefaults(), isExistingInstall: true)
        XCTAssertEqual(settings.dataSource, .eventKit)
    }

    func testStoredCalendarSelectionMeansExistingInstall() {
        let defaults = makeDefaults()
        defaults.set(["cal-1"], forKey: "selectedCalendarIDs")
        let settings = AppSettings(defaults: defaults, isExistingInstall: false)
        XCTAssertEqual(settings.dataSource, .eventKit)
    }

    func testFirstLaunchChoiceIsPersisted() {
        let defaults = makeDefaults()
        _ = AppSettings(defaults: defaults, isExistingInstall: false)
        // Granting calendar access later must not flip a fresh install over.
        let later = AppSettings(defaults: defaults, isExistingInstall: true)
        XCTAssertEqual(later.dataSource, .google)
    }

    func testChangedDataSourcePersists() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults, isExistingInstall: false)
        settings.dataSource = .eventKit
        XCTAssertEqual(AppSettings(defaults: defaults).dataSource, .eventKit)
    }

    // Review Focus 5: switching sources leaves each source's ticks alone.
    func testSelectionsAreSeparatePerSource() {
        let settings = AppSettings(defaults: makeDefaults(), isExistingInstall: true)
        settings.setSelected("ek-1", selected: false, in: .eventKit, currentlySelected: ["ek-1", "ek-2"])
        settings.dataSource = .google

        XCTAssertFalse(settings.isSelected("ek-1", in: .eventKit))
        XCTAssertTrue(settings.isSelected("ek-2", in: .eventKit))
        XCTAssertTrue(settings.isSelected("a@x.com/primary", in: .google, default: true))
        XCTAssertFalse(settings.isSelected("a@x.com/holidays", in: .google, default: false))
    }

    func testUnsetSelectionUsesTheCallersDefault() {
        let settings = AppSettings(defaults: makeDefaults())
        XCTAssertTrue(settings.isSelected("x", in: .google))
        XCTAssertFalse(settings.isSelected("x", in: .google, default: false))
    }

    func testFirstToggleSeedsFromCurrentlySelected() {
        let settings = AppSettings(defaults: makeDefaults())
        // "b" was off by default (unticked in Google); ticking "c" off must keep "b" off.
        settings.setSelected("c", selected: false, in: .google, currentlySelected: ["a", "c"])
        XCTAssertEqual(settings.selectedGoogleCalendarIDs, ["a"])
        XCTAssertFalse(settings.isSelected("b", in: .google, default: true))
    }
}
