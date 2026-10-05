# Google API Event Source Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the app fetch Google Calendar events itself by polling the Google Calendar API for several signed-in accounts. Settings gets a per-install switch between that and today's EventKit (macOS Calendar) source.

**Architecture:** A new `EventSource` protocol has two implementations. `EventKitSource` is today's EventKit code, moved out of `CalendarViewModel`. `GoogleAPISource` polls a 7-day window every 2 minutes per account. `GoogleAccountStore` replaces the single-account `GoogleCalendarService`: it keeps per-account Keychain tokens and makes the REST calls. `CalendarViewModel` stops importing EventKit and only renders the active source's `EventSnapshot`.

**Tech Stack:** Swift 5 language mode, SwiftUI `MenuBarExtra`, EventKit, `URLSession` + `JSONSerialization`, `ASWebAuthenticationSession` (PKCE), `Network.NWPathMonitor`, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-02-google-api-event-source-design.md`

## Global Constraints

- macOS 14 (Sonoma) or later. Xcode 26.5. Swift 5 language mode.
- No third-party SDKs or packages (PRD §2). Use Foundation, AppKit, SwiftUI, EventKit, AuthenticationServices, CryptoKit and Network only.
- Settings window copy is **Polish**. Pop-over / menu-bar copy is **English**. Match the existing strings.
- Build with `-derivedDataPath /tmp/mc-build`. Building inside the synced repo folder breaks `codesign`.
- The Xcode project lists files explicitly. Every new `.swift` file must be registered with `scripts/add-xcode-file.py` (created in Task 1), or it won't compile.
- `CalendarViewModel` must not start sources, timers or EventKit when `XCTestConfigurationFilePath` is set (the existing `isRunningTests` guard).
- Poll interval 120 s. Back off ×2 per throttled poll, capped at 600 s, reset after a good poll. Pop-over-open freshness 15 s. Event window: start of today → now + 7 days.
- Google calendar selection id: `"<accountEmail>/<calendarId>"`. Google event identifier: `"<accountEmail>/<calendarId>/<eventId>"`.
- OAuth scopes: `https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/calendar.calendarlist.readonly https://www.googleapis.com/auth/calendar.readonly`.
- Keychain service `com.rc.MenubarCalendar.google`, one item per account (Keychain account = email). The legacy item's Keychain account is `"tokens"`.

## Common commands

Run from the repo root (`/Users/radek/Repos/MenubarCalendar`).

```bash
# Build
xcodebuild -project MenubarCalendar.xcodeproj -scheme MenubarCalendar \
  -destination 'platform=macOS' -derivedDataPath /tmp/mc-build build 2>&1 \
  | grep -E "error:|warning: .*(GoogleA|EventSource|EventKitSource)|BUILD (SUCCEEDED|FAILED)"

# One test class (replace the class name)
xcodebuild -project MenubarCalendar.xcodeproj -scheme MenubarCalendar \
  -destination 'platform=macOS' -derivedDataPath /tmp/mc-build test \
  -only-testing:MenubarCalendarTests/AppSettingsTests 2>&1 \
  | grep -E "error:|failed|passed|TEST (SUCCEEDED|FAILED)" | tail -40

# All tests
xcodebuild -project MenubarCalendar.xcodeproj -scheme MenubarCalendar \
  -destination 'platform=macOS' -derivedDataPath /tmp/mc-build test 2>&1 \
  | grep -E "error:|failed|Executed|TEST (SUCCEEDED|FAILED)" | tail -20
```

## Review Focus

These are inputs no task's main tests cover that would most likely bite a real user. The owning task adds a test pinning each one.

1. **An all-day event on a DST-change day** (2026-10-25 in Europe/Warsaw) should still run local midnight to local midnight (25 h), not shift by an hour. *(Task 2)*
2. **Google rate-limiting with HTTP 403 `rateLimitExceeded`** should back off. It must not mark the account "needs reconnect". *(Task 3)*
3. **A meeting link that exists only inside an HTML `description`** (`<a href="https://tonik.zoom.us/j/123">`) should still be joinable through `EventLinkExtractor`. *(Task 2)*
4. **A primary calendar whose `calendarList` entry has no `selected` field** should count as selected by default, so a newly connected account doesn't come up empty. *(Task 2)*
5. **Switching the data source on an existing install** should leave each source's calendar ticks as they were, and default Google calendars to their Google-side selection. *(Task 1)*

---

### Task 1: Data-source setting, per-source calendar selection, Xcode file helper

**Files:**
- Create: `scripts/add-xcode-file.py`
- Modify: `MenubarCalendar/AppSettings.swift`
- Modify: `MenubarCalendar/CalendarViewModel.swift` (one call site)
- Modify: `MenubarCalendar/SettingsView.swift` (`calendarsSection`)
- Test: `MenubarCalendarTests/AppSettingsTests.swift` (new)

**Interfaces:**
- Produces:
  - `enum DataSource: String, CaseIterable { case google, eventKit }`
  - `AppSettings.init(defaults: UserDefaults = .standard, isExistingInstall: Bool = false)`
  - `@Published var dataSource: DataSource`
  - `@Published private(set) var selectedGoogleCalendarIDs: Set<String>?`
  - `func isSelected(_ id: String, in source: DataSource, default defaultValue: Bool = true) -> Bool`
  - `func setSelected(_ id: String, selected: Bool, in source: DataSource, currentlySelected: [String])`
  - The old `isSelected(_:)` and `setSelected(_:selected:allIDs:)` are **removed**.

- [ ] **Step 1: Create the Xcode file helper**

Create `scripts/add-xcode-file.py`:

```python
#!/usr/bin/env python3
"""Register a Swift file with MenubarCalendar.xcodeproj.

The project lists its files explicitly (no synchronized folders), so a new
.swift file compiles only once it has a file reference, a group entry and a
Sources build-phase entry. Run from the repo root:

    scripts/add-xcode-file.py app MenubarCalendar/Foo.swift
    scripts/add-xcode-file.py tests MenubarCalendarTests/FooTests.swift
"""
import os
import re
import sys

PBX = "MenubarCalendar.xcodeproj/project.pbxproj"
# Group and Sources-phase object ids per target (see project.pbxproj).
TARGETS = {
    "app": ("AAAA00000000000000000003", "AAAA0000000000000000000D"),
    "tests": ("AAAA00000000000000000005", "AAAA00000000000000000010"),
}


def main():
    target, path = sys.argv[1], sys.argv[2]
    group_id, phase_id = TARGETS[target]
    name = os.path.basename(path)
    with open(PBX) as f:
        text = f.read()
    if f"/* {name} */" in text:
        sys.exit(f"{name} is already in the project")

    top = max(int(h, 16) for h in re.findall(r"AAAA([0-9A-F]{20})", text))
    build_id, ref_id = f"AAAA{top + 1:020X}", f"AAAA{top + 2:020X}"

    def insert_after(text, anchor, line, start=0):
        i = text.index(anchor, start) + len(anchor)
        return text[:i] + line + text[i:]

    text = insert_after(
        text, "/* Begin PBXBuildFile section */\n",
        f"\t\t{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; "
        f"fileRef = {ref_id} /* {name} */; }};\n")
    text = insert_after(
        text, "/* Begin PBXFileReference section */\n",
        f"\t\t{ref_id} /* {name} */ = {{isa = PBXFileReference; "
        f"lastKnownFileType = sourcecode.swift; path = {name}; "
        f"sourceTree = \"<group>\"; }};\n")
    group = text.index(f"\n\t\t{group_id} /* ", text.index("/* Begin PBXGroup section */"))
    text = insert_after(text, "children = (\n", f"\t\t\t\t{ref_id} /* {name} */,\n", group)
    phase = text.index(f"\t\t{phase_id} /* Sources */ = {{")
    text = insert_after(text, "files = (\n", f"\t\t\t\t{build_id} /* {name} in Sources */,\n", phase)

    with open(PBX, "w") as f:
        f.write(text)
    print(f"added {name}: build {build_id}, ref {ref_id}")


if __name__ == "__main__":
    main()
```

Run: `chmod +x scripts/add-xcode-file.py`

- [ ] **Step 2: Write the failing tests**

Create `MenubarCalendarTests/AppSettingsTests.swift`:

```swift
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
```

Register it: `scripts/add-xcode-file.py tests MenubarCalendarTests/AppSettingsTests.swift`

- [ ] **Step 3: Run the tests to make sure they fail**

Run the "One test class" command with `AppSettingsTests`.
Expected: compile failure: `extra argument 'isExistingInstall' in call` / `cannot find 'DataSource'`.

- [ ] **Step 4: Implement in `AppSettings.swift`**

Add above `final class AppSettings`:

```swift
/// Where events come from — one per install, never both at once (spec
/// 2026-10-02). `.google` polls the Google Calendar API directly; `.eventKit`
/// reads whatever accounts macOS's Calendar database has.
enum DataSource: String, CaseIterable {
    case google
    case eventKit
}
```

In `Keys` add:

```swift
        static let dataSource = "dataSource"
        static let selectedGoogleCalendarIDs = "selectedGoogleCalendarIDs"
```

Under `@Published private(set) var selectedCalendarIDs: Set<String>?` add:

```swift
    /// Like `selectedCalendarIDs`, for Google calendars (`"<email>/<calendarId>"`).
    /// `nil` means "use each calendar's default" (its Google-side selection).
    @Published private(set) var selectedGoogleCalendarIDs: Set<String>?

    @Published var dataSource: DataSource {
        didSet { defaults.set(dataSource.rawValue, forKey: Keys.dataSource) }
    }
```

Change the initializer signature and add the following at the **end** of `init`, after `chromeProfileOverrides`:

```swift
    /// `isExistingInstall` is true when this Mac already granted the app
    /// calendar access — i.e. someone was using the EventKit source before the
    /// switch existed. Only consulted the first time; the result is stored.
    init(defaults: UserDefaults = .standard, isExistingInstall: Bool = false) {
```

```swift
        if let stored = defaults.array(forKey: Keys.selectedGoogleCalendarIDs) as? [String] {
            self.selectedGoogleCalendarIDs = Set(stored)
        } else {
            self.selectedGoogleCalendarIDs = nil
        }

        if let raw = defaults.string(forKey: Keys.dataSource), let stored = DataSource(rawValue: raw) {
            self.dataSource = stored
        } else {
            let existing = isExistingInstall || defaults.object(forKey: Keys.selectedCalendarIDs) != nil
            let initial: DataSource = existing ? .eventKit : .google
            defaults.set(initial.rawValue, forKey: Keys.dataSource)
            self.dataSource = initial
        }
```

Replace the two selection methods at the bottom of the class with:

```swift
    /// Whether a calendar is included. Before the user has touched that
    /// source's list, `defaultValue` decides (true for EventKit; the calendar's
    /// Google-side selection for Google).
    func isSelected(_ id: String, in source: DataSource, default defaultValue: Bool = true) -> Bool {
        selection(for: source)?.contains(id) ?? defaultValue
    }

    /// Toggle a calendar. `currentlySelected` seeds the set on the first change
    /// so the rest of the list keeps its current state.
    func setSelected(_ id: String, selected: Bool, in source: DataSource, currentlySelected: [String]) {
        var set = selection(for: source) ?? Set(currentlySelected)
        if selected {
            set.insert(id)
        } else {
            set.remove(id)
        }
        switch source {
        case .eventKit:
            selectedCalendarIDs = set
            defaults.set(Array(set), forKey: Keys.selectedCalendarIDs)
        case .google:
            selectedGoogleCalendarIDs = set
            defaults.set(Array(set), forKey: Keys.selectedGoogleCalendarIDs)
        }
    }

    private func selection(for source: DataSource) -> Set<String>? {
        switch source {
        case .eventKit: selectedCalendarIDs
        case .google: selectedGoogleCalendarIDs
        }
    }
```

Update the class doc comment's first paragraph so it mentions per-source selection ("`selectedCalendarIDs` / `selectedGoogleCalendarIDs == nil` means 'defaults'…").

- [ ] **Step 5: Update the two call sites**

In `CalendarViewModel.swift`, `reload()`:

```swift
        let selected = allCalendars.filter { settings.isSelected($0.calendarIdentifier, in: .eventKit) }
```

In `SettingsView.swift`, `calendarsSection`, replace the `Toggle(isOn:)` binding:

```swift
                    Toggle(isOn: Binding(
                        get: { settings.isSelected(calendar.id, in: .eventKit) },
                        set: { newValue in
                            settings.setSelected(
                                calendar.id,
                                selected: newValue,
                                in: .eventKit,
                                currentlySelected: viewModel.availableCalendars
                                    .filter { settings.isSelected($0.id, in: .eventKit) }
                                    .map(\.id)
                            )
                        }
                    )) {
```

(Task 6 switches `.eventKit` here to the active source.)

- [ ] **Step 6: Run the tests to make sure they pass**

Run `AppSettingsTests`, then "All tests". Expected: `TEST SUCCEEDED`, and all existing tests pass too.

- [ ] **Step 7: Commit**

```bash
git add scripts/add-xcode-file.py MenubarCalendar/AppSettings.swift MenubarCalendar/CalendarViewModel.swift \
  MenubarCalendar/SettingsView.swift MenubarCalendarTests/AppSettingsTests.swift MenubarCalendar.xcodeproj/project.pbxproj
git commit -m "Add a per-install data source setting and per-source calendar selection"
```

---

### Task 2: `GoogleEventMapper`: Google JSON to `CalendarEvent`

**Files:**
- Modify: `MenubarCalendar/Models/CalendarEvent.swift`
- Create: `MenubarCalendar/GoogleEventMapper.swift`
- Test: `MenubarCalendarTests/GoogleEventMapperTests.swift` (new)

**Interfaces:**
- Produces:
  - New `CalendarEvent` fields, all defaulted: `var iCalUID: String? = nil`, `var isEditable: Bool = false`, `var canDecline: Bool = false`.
  - `struct GoogleCalendarEntry: Equatable { key, accountEmail, calendarID, title: String; colorHex: String?; isWritable: Bool; isSelectedInGoogle: Bool }`
  - `struct MappedGoogleEvent: Equatable { event: CalendarEvent; calendarID: String; eventID: String; hasSelfAttendee: Bool }`
  - `enum GoogleEventMapper` with:
    - `static func calendarKey(accountEmail:calendarID:) -> String`
    - `static func calendar(from: [String: Any], accountEmail: String) -> GoogleCalendarEntry?`
    - `static func event(from: [String: Any], calendar: GoogleCalendarEntry, timeZone: TimeZone = .current) -> MappedGoogleEvent?`
    - `static func dedupe(_: [MappedGoogleEvent]) -> [MappedGoogleEvent]`
    - `static func rfc3339(_: Date) -> String`

- [ ] **Step 1: Add the `CalendarEvent` fields**

In `Models/CalendarEvent.swift`, append after `accountEmail`:

```swift
    /// The iCalendar UID, shared by every copy of an invitation — used to spot
    /// the same meeting seen through two accounts and to hide declines.
    var iCalUID: String? = nil
    /// Whether the edit screen may write this event (macOS Calendar source only).
    var isEditable: Bool = false
    /// Whether Decline applies: a writable calendar the user is invited on.
    var canDecline: Bool = false
```

- [ ] **Step 2: Write the failing tests**

Create `MenubarCalendarTests/GoogleEventMapperTests.swift`:

```swift
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

    private func copy(account: String, uid: String?, start: Date, isAttendee: Bool) -> MappedGoogleEvent {
        MappedGoogleEvent(
            event: CalendarEvent(
                identifier: "\(account)/cal/\(uid ?? "x")", title: "Sync", startDate: start,
                endDate: start.addingTimeInterval(1800), isAllDay: false,
                calendarIdentifier: "\(account)/cal", calendarTitle: "cal",
                accountEmail: account, iCalUID: uid
            ),
            calendarID: "cal", eventID: uid ?? "x", hasSelfAttendee: isAttendee
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
```

Register both files:

```bash
scripts/add-xcode-file.py app MenubarCalendar/GoogleEventMapper.swift
scripts/add-xcode-file.py tests MenubarCalendarTests/GoogleEventMapperTests.swift
```

Create `MenubarCalendar/GoogleEventMapper.swift` with just `import Foundation` so the project file reference resolves.

- [ ] **Step 3: Run the tests to make sure they fail**

Run `GoogleEventMapperTests`. Expected: compile failure, `cannot find 'GoogleCalendarEntry' in scope`.

- [ ] **Step 4: Implement `GoogleEventMapper.swift`**

```swift
import Foundation

/// A calendar from `calendarList.list`, tagged with the account it came through.
struct GoogleCalendarEntry: Equatable {
    /// `"<account>/<calendar id>"` — unique across accounts; the selection id
    /// and `CalendarEvent.calendarIdentifier`.
    let key: String
    let accountEmail: String
    let calendarID: String
    let title: String
    /// `#rrggbb`, Google's `backgroundColor`.
    let colorHex: String?
    /// Owner / writer access — needed to send an RSVP through this calendar.
    let isWritable: Bool
    /// Ticked in Google Calendar's own sidebar: the default selection here
    /// until the user changes it in Settings.
    let isSelectedInGoogle: Bool
}

/// An event mapped from Google JSON, plus the ids needed to act on it.
struct MappedGoogleEvent: Equatable {
    let event: CalendarEvent
    let calendarID: String
    /// Per-occurrence id (the API is queried with `singleEvents=true`).
    let eventID: String
    /// The account is listed as an attendee (`self == true`).
    let hasSelfAttendee: Bool
}

/// Pure JSON → model mapping for the Google Calendar API, kept free of
/// networking so it can be tested against literal API payloads.
enum GoogleEventMapper {
    static func calendarKey(accountEmail: String, calendarID: String) -> String {
        "\(accountEmail)/\(calendarID)"
    }

    static func calendar(from json: [String: Any], accountEmail: String) -> GoogleCalendarEntry? {
        guard let id = json["id"] as? String else { return nil }
        let role = json["accessRole"] as? String ?? ""
        let isPrimary = json["primary"] as? Bool ?? false
        return GoogleCalendarEntry(
            key: calendarKey(accountEmail: accountEmail, calendarID: id),
            accountEmail: accountEmail,
            calendarID: id,
            title: json["summaryOverride"] as? String ?? json["summary"] as? String ?? id,
            colorHex: json["backgroundColor"] as? String,
            isWritable: role == "owner" || role == "writer",
            // Google omits `selected` when false — except it can omit it on the
            // primary calendar too, which should never start hidden.
            isSelectedInGoogle: json["selected"] as? Bool ?? isPrimary
        )
    }

    /// `nil` for cancelled occurrences, events the account declined, and
    /// payloads without usable times.
    static func event(
        from json: [String: Any], calendar: GoogleCalendarEntry, timeZone: TimeZone = .current
    ) -> MappedGoogleEvent? {
        guard (json["status"] as? String) != "cancelled",
              let eventID = json["id"] as? String,
              let start = (json["start"] as? [String: Any]).flatMap({ time(from: $0, timeZone: timeZone) }),
              let end = (json["end"] as? [String: Any]).flatMap({ time(from: $0, timeZone: timeZone) })
        else { return nil }

        let attendees = json["attendees"] as? [[String: Any]] ?? []
        let me = attendees.first { ($0["self"] as? Bool) == true }
        if (me?["responseStatus"] as? String) == "declined" { return nil }

        let event = CalendarEvent(
            identifier: "\(calendar.key)/\(eventID)",
            title: json["summary"] as? String ?? "",
            startDate: start.date,
            endDate: end.date,
            isAllDay: start.isAllDay,
            calendarIdentifier: calendar.key,
            calendarTitle: calendar.title,
            url: meetingURL(from: json),
            location: json["location"] as? String,
            notes: json["description"] as? String,
            accountEmail: calendar.accountEmail,
            iCalUID: json["iCalUID"] as? String,
            isEditable: false,
            canDecline: calendar.isWritable && me != nil
        )
        return MappedGoogleEvent(
            event: event, calendarID: calendar.calendarID, eventID: eventID, hasSelfAttendee: me != nil
        )
    }

    /// The same meeting can arrive through two accounts (invited on both, or a
    /// calendar shared into both). Keep one copy per (iCalUID, start): the first
    /// whose account is an attendee, else the first seen. Input order is
    /// account connection order. Events without a UID are all kept.
    static func dedupe(_ events: [MappedGoogleEvent]) -> [MappedGoogleEvent] {
        var indexByKey: [String: Int] = [:]
        var result: [MappedGoogleEvent] = []
        for item in events {
            guard let uid = item.event.iCalUID else {
                result.append(item)
                continue
            }
            let key = "\(uid)@\(item.event.startDate.timeIntervalSince1970)"
            if let index = indexByKey[key] {
                if !result[index].hasSelfAttendee && item.hasSelfAttendee {
                    result[index] = item
                }
            } else {
                indexByKey[key] = result.count
                result.append(item)
            }
        }
        return result
    }

    /// RFC 3339 in UTC, for `timeMin` / `timeMax`.
    static func rfc3339(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    // MARK: - Private

    private static func meetingURL(from json: [String: Any]) -> URL? {
        if let link = json["hangoutLink"] as? String, let url = URL(string: link) {
            return url
        }
        let entryPoints = (json["conferenceData"] as? [String: Any])?["entryPoints"] as? [[String: Any]] ?? []
        guard let video = entryPoints.first(where: { ($0["entryPointType"] as? String) == "video" }),
              let uri = video["uri"] as? String else { return nil }
        return URL(string: uri)
    }

    /// Timed events carry `dateTime` (RFC 3339 with offset); all-day events
    /// carry `date` (`yyyy-MM-dd`, end exclusive), read as local midnight.
    private static func time(from field: [String: Any], timeZone: TimeZone) -> (date: Date, isAllDay: Bool)? {
        if let value = field["dateTime"] as? String {
            return parseDateTime(value).map { ($0, false) }
        }
        if let value = field["date"] as? String {
            return parseDay(value, timeZone: timeZone).map { ($0, true) }
        }
        return nil
    }

    private static func parseDateTime(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    private static func parseDay(_ value: String, timeZone: TimeZone) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
```

- [ ] **Step 5: Run the tests to make sure they pass**

Run `GoogleEventMapperTests`, then "All tests". Expected: `TEST SUCCEEDED`.

If `testLinkOnlyInHTMLDescriptionIsJoinable` fails because `EventLinkExtractor` keeps the trailing `"` or `>`, fix the extractor's URL pattern so it stops at `"`, `'`, `<` and `>`. Add an `EventLinkExtractorTests` case for that HTML input. Don't weaken this test.

- [ ] **Step 6: Commit**

```bash
git add MenubarCalendar/Models/CalendarEvent.swift MenubarCalendar/GoogleEventMapper.swift \
  MenubarCalendarTests/GoogleEventMapperTests.swift MenubarCalendar.xcodeproj/project.pbxproj
git commit -m "Map Google Calendar API events and calendars to the app's model"
```

(Include `MenubarCalendar/EventLinkExtractor.swift` and its tests if Step 5 required the fix.)

---

### Task 3: `GoogleAccountStore`: several Google accounts

**Files:**
- Rename: `MenubarCalendar/GoogleCalendarService.swift` → `MenubarCalendar/GoogleAccountStore.swift` (contents fully replaced)
- Modify: `MenubarCalendar.xcodeproj/project.pbxproj` (rename references)
- Modify: `MenubarCalendar/MenubarCalendarApp.swift`, `MenubarCalendar/CalendarViewModel.swift`, `MenubarCalendar/EventListView.swift`, `MenubarCalendar/SettingsView.swift`
- Test: `MenubarCalendarTests/GoogleAccountStoreTests.swift` (new)

**Interfaces:**
- Produces:
  - `protocol TokenVault { func save(_ data: Data, account: String); func load(account: String) -> Data?; func delete(account: String) }`
  - `struct KeychainVault: TokenVault`
  - `struct GoogleTokens: Codable` (now internal) with `accessToken`, `refreshToken`, `expiry: Date`, `email: String?`
  - `struct GoogleAccount: Identifiable, Equatable { email: String; needsReconnect: Bool; lastSync: Date? }`
  - `@MainActor final class GoogleAccountStore: ObservableObject` with:
    - `@Published private(set) var accounts: [GoogleAccount]`
    - `@Published private(set) var isBusy: Bool`
    - `@Published var errorMessage: String?`
    - `var isConfigured: Bool`
    - `var hasUsableAccount: Bool`
    - `init(vault: TokenVault = KeychainVault(), defaults: UserDefaults = .standard)`
    - `func addAccount() async`
    - `func store(_ tokens: GoogleTokens, for email: String)`
    - `func remove(email: String)`
    - `func markNeedsReconnect(email: String)`
    - `func recordSync(email: String, at: Date = Date())`
    - `func getJSON(_ url: URL, as email: String) async throws -> [String: Any]`
    - `func declineEvent(iCalUID: String, as email: String) async throws -> Bool`
    - `func declineInstance(calendarID: String, eventID: String, as email: String) async throws -> Bool`
    - `func reportDeclineFailure(_ error: Error)`
    - `static func isAuthFailure(_ error: Error) -> Bool`
    - `static func isRateLimited(_ error: Error) -> Bool`
  - Errors from HTTP are `NSError(domain: "GoogleCalendar", code: <status>, userInfo: [NSLocalizedDescriptionKey: <body>])`.

- [ ] **Step 1: Rename the file**

```bash
git mv MenubarCalendar/GoogleCalendarService.swift MenubarCalendar/GoogleAccountStore.swift
sed -i '' 's/GoogleCalendarService\.swift/GoogleAccountStore.swift/g' MenubarCalendar.xcodeproj/project.pbxproj
grep -c "GoogleAccountStore.swift" MenubarCalendar.xcodeproj/project.pbxproj   # expect 4
```

- [ ] **Step 2: Write the failing tests**

Create `MenubarCalendarTests/GoogleAccountStoreTests.swift`:

```swift
import XCTest
@testable import MenubarCalendar

/// Token storage double, so tests never touch the real Keychain.
final class InMemoryVault: TokenVault {
    var items: [String: Data] = [:]
    func save(_ data: Data, account: String) { items[account] = data }
    func load(account: String) -> Data? { items[account] }
    func delete(account: String) { items[account] = nil }
}

@MainActor
final class GoogleAccountStoreTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "GoogleAccountStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func tokens(_ email: String?) -> GoogleTokens {
        GoogleTokens(accessToken: "access", refreshToken: "refresh", expiry: .distantFuture, email: email)
    }

    private func encoded(_ tokens: GoogleTokens) -> Data {
        try! JSONEncoder().encode(tokens)
    }

    func testMigratesTheLegacySingleAccountItem() {
        let vault = InMemoryVault()
        vault.items["tokens"] = encoded(tokens("mail@radekcabaj.com"))
        let defaults = makeDefaults()

        let store = GoogleAccountStore(vault: vault, defaults: defaults)

        XCTAssertEqual(store.accounts.map(\.email), ["mail@radekcabaj.com"])
        XCTAssertNil(vault.items["tokens"])
        XCTAssertNotNil(vault.items["mail@radekcabaj.com"])
        XCTAssertEqual(defaults.stringArray(forKey: "googleAccountOrder"), ["mail@radekcabaj.com"])
        XCTAssertTrue(store.hasUsableAccount)
    }

    func testLegacyItemWithoutEmailIsDropped() {
        let vault = InMemoryVault()
        vault.items["tokens"] = encoded(tokens(nil))
        let store = GoogleAccountStore(vault: vault, defaults: makeDefaults())
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertTrue(vault.items.isEmpty)
    }

    func testAccountsLoadInStoredOrderAndSkipMissingTokens() {
        let vault = InMemoryVault()
        vault.items["b@x.com"] = encoded(tokens("b@x.com"))
        vault.items["a@x.com"] = encoded(tokens("a@x.com"))
        let defaults = makeDefaults()
        defaults.set(["b@x.com", "gone@x.com", "a@x.com"], forKey: "googleAccountOrder")

        let store = GoogleAccountStore(vault: vault, defaults: defaults)
        XCTAssertEqual(store.accounts.map(\.email), ["b@x.com", "a@x.com"])
    }

    func testStoreAppendsNewAccountsAndClearsReconnectOnExisting() {
        let defaults = makeDefaults()
        let store = GoogleAccountStore(vault: InMemoryVault(), defaults: defaults)
        store.store(tokens("a@x.com"), for: "a@x.com")
        store.store(tokens("b@x.com"), for: "b@x.com")
        store.markNeedsReconnect(email: "a@x.com")
        XCTAssertTrue(store.accounts[0].needsReconnect)

        store.store(tokens("a@x.com"), for: "a@x.com")

        XCTAssertEqual(store.accounts.map(\.email), ["a@x.com", "b@x.com"])
        XCTAssertFalse(store.accounts[0].needsReconnect)
        XCTAssertEqual(defaults.stringArray(forKey: "googleAccountOrder"), ["a@x.com", "b@x.com"])
    }

    func testRemoveDeletesTokensAndOrder() {
        let vault = InMemoryVault()
        let defaults = makeDefaults()
        let store = GoogleAccountStore(vault: vault, defaults: defaults)
        store.store(tokens("a@x.com"), for: "a@x.com")
        store.store(tokens("b@x.com"), for: "b@x.com")

        store.remove(email: "a@x.com")

        XCTAssertEqual(store.accounts.map(\.email), ["b@x.com"])
        XCTAssertNil(vault.items["a@x.com"])
        XCTAssertEqual(defaults.stringArray(forKey: "googleAccountOrder"), ["b@x.com"])
    }

    func testHasUsableAccountIgnoresAccountsNeedingReconnect() {
        let store = GoogleAccountStore(vault: InMemoryVault(), defaults: makeDefaults())
        XCTAssertFalse(store.hasUsableAccount)
        store.store(tokens("a@x.com"), for: "a@x.com")
        store.markNeedsReconnect(email: "a@x.com")
        XCTAssertFalse(store.hasUsableAccount)
    }

    func testRecordSync() {
        let store = GoogleAccountStore(vault: InMemoryVault(), defaults: makeDefaults())
        store.store(tokens("a@x.com"), for: "a@x.com")
        let when = Date(timeIntervalSince1970: 1_000)
        store.recordSync(email: "a@x.com", at: when)
        XCTAssertEqual(store.accounts[0].lastSync, when)
    }

    // MARK: Error classification

    private func httpError(_ code: Int, _ body: String = "") -> NSError {
        NSError(domain: "GoogleCalendar", code: code, userInfo: [NSLocalizedDescriptionKey: body])
    }

    func testUnauthorizedIsAuthFailure() {
        XCTAssertTrue(GoogleAccountStore.isAuthFailure(httpError(401)))
        XCTAssertTrue(GoogleAccountStore.isAuthFailure(httpError(403, #"{"error":{"errors":[{"reason":"insufficientPermissions"}]}}"#)))
        XCTAssertTrue(GoogleAccountStore.isAuthFailure(URLError(.userAuthenticationRequired)))
    }

    // Review Focus 2: Google rate-limits with 403 too; that must back off, not reconnect.
    func testRateLimited403IsNotAnAuthFailure() {
        let error = httpError(403, #"{"error":{"errors":[{"domain":"usageLimits","reason":"rateLimitExceeded"}]}}"#)
        XCTAssertTrue(GoogleAccountStore.isRateLimited(error))
        XCTAssertFalse(GoogleAccountStore.isAuthFailure(error))
        XCTAssertTrue(GoogleAccountStore.isRateLimited(httpError(403, "userRateLimitExceeded")))
        XCTAssertTrue(GoogleAccountStore.isRateLimited(httpError(429)))
    }

    func testNetworkErrorsAreNeither() {
        let offline = URLError(.notConnectedToInternet)
        XCTAssertFalse(GoogleAccountStore.isAuthFailure(offline))
        XCTAssertFalse(GoogleAccountStore.isRateLimited(offline))
        XCTAssertFalse(GoogleAccountStore.isAuthFailure(httpError(500)))
    }
}
```

Register: `scripts/add-xcode-file.py tests MenubarCalendarTests/GoogleAccountStoreTests.swift`

- [ ] **Step 3: Run the tests to make sure they fail**

Run `GoogleAccountStoreTests`. Expected: compile failure, `cannot find 'TokenVault' in scope`.

- [ ] **Step 4: Replace the contents of `GoogleAccountStore.swift`**

```swift
import AppKit
import AuthenticationServices
import CryptoKit
import Foundation

/// The Google accounts the app is signed in to, and every Google Calendar REST
/// call made with them: reading calendars/events (the Google data source) and
/// sending a real "declined" RSVP with `sendUpdates=all` (both data sources —
/// EventKit has no public RSVP API).
///
/// Each account has its own OAuth tokens in the Keychain, so an event fetched
/// through an account knows which account owns it (Chrome-profile routing,
/// `authuser=`). An account whose token is revoked or lacks a scope is marked
/// `needsReconnect`; the others keep working.
///
/// No third-party SDKs (PRD §2): OAuth (PKCE), token refresh and the REST calls
/// are implemented on `URLSession` + `JSONSerialization`.
@MainActor
final class GoogleAccountStore: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    /// Connected accounts, in connection order (which also breaks ties when
    /// the same meeting is seen through two accounts).
    @Published private(set) var accounts: [GoogleAccount] = []
    /// Set while a sign-in is in flight, to disable the UI buttons.
    @Published private(set) var isBusy = false
    /// Last user-facing error (e.g. missing client id, failed decline).
    @Published var errorMessage: String?

    private let vault: TokenVault
    private let defaults: UserDefaults
    private var tokens: [String: GoogleTokens] = [:]

    private static let orderKey = "googleAccountOrder"
    /// Keychain account of the single item written before multi-account support.
    private static let legacyVaultAccount = "tokens"

    /// Whether the app was built with a Google client id configured.
    var isConfigured: Bool { GoogleConfig.clientID != nil }

    /// At least one account can make API calls right now.
    var hasUsableAccount: Bool { accounts.contains { !$0.needsReconnect } }

    init(vault: TokenVault = KeychainVault(), defaults: UserDefaults = .standard) {
        self.vault = vault
        self.defaults = defaults
        super.init()
        migrateLegacyTokens()
        let order = defaults.stringArray(forKey: Self.orderKey) ?? []
        for email in order {
            if let data = vault.load(account: email),
               let decoded = try? JSONDecoder().decode(GoogleTokens.self, from: data) {
                tokens[email] = decoded
            }
        }
        accounts = order.filter { tokens[$0] != nil }.map { GoogleAccount(email: $0) }
    }

    /// Move the pre-multi-account item to a per-email item, first in order. It
    /// was minted without `calendar.readonly`, so its first read 403s and marks
    /// it `needsReconnect` — Settings then asks for one reconnect.
    private func migrateLegacyTokens() {
        guard let data = vault.load(account: Self.legacyVaultAccount) else { return }
        vault.delete(account: Self.legacyVaultAccount)
        guard let legacy = try? JSONDecoder().decode(GoogleTokens.self, from: data),
              let email = legacy.email else { return } // no email to key it by: reconnect
        vault.save(data, account: email)
        var order = defaults.stringArray(forKey: Self.orderKey) ?? []
        order.removeAll { $0 == email }
        order.insert(email, at: 0)
        defaults.set(order, forKey: Self.orderKey)
    }

    // MARK: - Accounts

    /// Run the OAuth flow for a new account — or an existing one, which
    /// refreshes its tokens and clears `needsReconnect`. Safe to call from the UI.
    func addAccount() async {
        guard let clientID = GoogleConfig.clientID else {
            errorMessage = "No Google client ID configured (see setup notes)."
            return
        }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let verifier = Self.randomCodeVerifier()
            let challenge = Self.codeChallenge(for: verifier)
            let code = try await authorize(clientID: clientID, challenge: challenge)
            var newTokens = try await exchange(code: code, verifier: verifier, clientID: clientID)
            guard let email = try await fetchPrimaryEmail(accessToken: newTokens.accessToken) else {
                errorMessage = "Couldn't read the Google account's email address."
                return
            }
            newTokens.email = email
            store(newTokens, for: email)
        } catch {
            if let asError = error as? ASWebAuthenticationSessionError, asError.code == .canceledLogin {
                // User closed the sheet — not an error worth surfacing loudly.
                errorMessage = nil
            } else {
                errorMessage = "Google sign-in failed: \(error.localizedDescription)"
            }
        }
    }

    /// Persist tokens for `email`: append a new account, or refresh an existing
    /// one and clear its reconnect flag.
    func store(_ newTokens: GoogleTokens, for email: String) {
        guard let data = try? JSONEncoder().encode(newTokens) else { return }
        vault.save(data, account: email)
        tokens[email] = newTokens
        if let index = accounts.firstIndex(where: { $0.email == email }) {
            accounts[index].needsReconnect = false
        } else {
            accounts.append(GoogleAccount(email: email))
            defaults.set(accounts.map(\.email), forKey: Self.orderKey)
        }
    }

    func remove(email: String) {
        vault.delete(account: email)
        tokens[email] = nil
        accounts.removeAll { $0.email == email }
        defaults.set(accounts.map(\.email), forKey: Self.orderKey)
    }

    func markNeedsReconnect(email: String) {
        guard let index = accounts.firstIndex(where: { $0.email == email }),
              !accounts[index].needsReconnect else { return }
        accounts[index].needsReconnect = true
    }

    func recordSync(email: String, at date: Date = Date()) {
        guard let index = accounts.firstIndex(where: { $0.email == email }) else { return }
        accounts[index].lastSync = date
    }

    // MARK: - Error classification

    /// Google answers some rate limits with 403 (`rateLimitExceeded`,
    /// `userRateLimitExceeded`, `quotaExceeded`) — those must back off, not
    /// force a reconnect.
    static func isRateLimited(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == "GoogleCalendar" else { return false }
        if ns.code == 429 { return true }
        let body = ns.localizedDescription.lowercased()
        return ns.code == 403 && (body.contains("ratelimitexceeded") || body.contains("quotaexceeded"))
    }

    /// The token is revoked, expired or missing a scope: only signing in again helps.
    static func isAuthFailure(_ error: Error) -> Bool {
        if (error as? URLError)?.code == .userAuthenticationRequired { return true }
        let ns = error as NSError
        return ns.domain == "GoogleCalendar" && (ns.code == 401 || ns.code == 403) && !isRateLimited(error)
    }

    /// Surface a failed decline. The account was already marked for reconnect
    /// if the failure was about auth. Callers must NOT hide the event on these,
    /// or the user is left hidden-but-still-attending.
    func reportDeclineFailure(_ error: Error) {
        if Self.isAuthFailure(error) {
            errorMessage = "Google needs to be reconnected to decline events (its permissions changed). Open Settings and connect again."
        } else {
            errorMessage = "Couldn't send the decline to Google: \(error.localizedDescription)"
        }
    }

    // MARK: - Reading

    /// GET a Calendar API URL as `email`. An auth failure marks that account
    /// for reconnecting before rethrowing.
    func getJSON(_ url: URL, as email: String) async throws -> [String: Any] {
        try await markingAuthFailures(of: email) {
            let token = try await validAccessToken(for: email)
            return try await get(url: url, token: token)
        }
    }

    // MARK: - Declining

    /// Decline by iCal UID on whichever writable calendar of `email` has it
    /// (macOS Calendar source, where only the UID is known). Returns `false` if
    /// no writable copy was found or the account isn't an attendee.
    func declineEvent(iCalUID: String, as email: String) async throws -> Bool {
        try await markingAuthFailures(of: email) {
            let token = try await validAccessToken(for: email)
            for calendar in try await writableCalendars(token: token) {
                guard let event = try await findEvent(calendarID: calendar, iCalUID: iCalUID, token: token) else {
                    continue
                }
                return try await sendDecline(event, calendarID: calendar, token: token)
            }
            return false
        }
    }

    /// Decline one known occurrence (Google source, which has the exact ids).
    func declineInstance(calendarID: String, eventID: String, as email: String) async throws -> Bool {
        try await markingAuthFailures(of: email) {
            let token = try await validAccessToken(for: email)
            let event = try await get(url: eventURL(calendarID: calendarID, eventID: eventID), token: token)
            return try await sendDecline(event, calendarID: calendarID, token: token)
        }
    }

    /// Set the account's own attendee entry to declined, notifying everyone.
    /// `false` if the account isn't a listed attendee (e.g. organizer only).
    private func sendDecline(_ event: [String: Any], calendarID: String, token: String) async throws -> Bool {
        guard var attendees = event["attendees"] as? [[String: Any]],
              let selfIndex = attendees.firstIndex(where: { ($0["self"] as? Bool) == true }),
              let eventID = event["id"] as? String
        else { return false }
        attendees[selfIndex]["responseStatus"] = "declined"
        try await patch(calendarID: calendarID, eventID: eventID, body: ["attendees": attendees], token: token)
        return true
    }

    private func markingAuthFailures<T>(of email: String, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            if Self.isAuthFailure(error) { markNeedsReconnect(email: email) }
            throw error
        }
    }

    // MARK: - OAuth

    private func authorize(clientID: String, challenge: String) async throws -> String {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: GoogleConfig.redirectURI(clientID: clientID)),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: GoogleConfig.scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            // `select_account` so adding a second account doesn't silently
            // reuse the one already signed in to the browser session.
            .init(name: "prompt", value: "consent select_account"),
        ]
        let authURL = components.url!
        let scheme = GoogleConfig.redirectScheme(clientID: clientID)

        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: scheme) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: error ?? URLError(.badServerResponse))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            if !session.start() {
                continuation.resume(throwing: URLError(.cannotConnectToHost))
            }
        }

        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            throw URLError(.userAuthenticationRequired)
        }
        return code
    }

    private func exchange(code: String, verifier: String, clientID: String) async throws -> GoogleTokens {
        let form: [String: String] = [
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": GoogleConfig.redirectURI(clientID: clientID),
        ]
        let json = try await postForm(url: "https://oauth2.googleapis.com/token", fields: form)
        guard let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String,
              let expiresIn = json["expires_in"] as? Double else {
            throw URLError(.cannotParseResponse)
        }
        return GoogleTokens(
            accessToken: access,
            refreshToken: refresh,
            expiry: Date().addingTimeInterval(expiresIn - 60),
            email: nil
        )
    }

    /// A non-expired access token for `email`, refreshing if needed. A rejected
    /// refresh token (revoked / expired) marks the account `needsReconnect`;
    /// a network failure just throws, leaving the account as it is.
    private func validAccessToken(for email: String) async throws -> String {
        guard var current = tokens[email] else { throw URLError(.userAuthenticationRequired) }
        guard Date() >= current.expiry else { return current.accessToken }
        guard let clientID = GoogleConfig.clientID else { throw URLError(.userAuthenticationRequired) }

        let form: [String: String] = [
            "client_id": clientID,
            "refresh_token": current.refreshToken,
            "grant_type": "refresh_token",
        ]
        let json: [String: Any]
        do {
            json = try await postForm(url: "https://oauth2.googleapis.com/token", fields: form)
        } catch let error as NSError where error.domain == "GoogleCalendar" && (400..<500).contains(error.code) {
            markNeedsReconnect(email: email)
            throw URLError(.userAuthenticationRequired)
        }
        guard let access = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? Double else {
            markNeedsReconnect(email: email)
            throw URLError(.userAuthenticationRequired)
        }
        current.accessToken = access
        current.expiry = Date().addingTimeInterval(expiresIn - 60)
        // Google may or may not return a new refresh token; keep the old if not.
        if let newRefresh = json["refresh_token"] as? String {
            current.refreshToken = newRefresh
        }
        if let data = try? JSONEncoder().encode(current) {
            vault.save(data, account: email)
        }
        tokens[email] = current
        return access
    }

    // MARK: - REST helpers

    /// Calendar ids the account can write to (owner / writer access).
    private func writableCalendars(token: String) async throws -> [String] {
        let json = try await get(
            url: URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!,
            token: token
        )
        let items = json["items"] as? [[String: Any]] ?? []
        // Primary first so the common case (own invitation) resolves fastest.
        let writable = items.filter { ["owner", "writer"].contains($0["accessRole"] as? String ?? "") }
        return writable
            .sorted { (($0["primary"] as? Bool) == true ? 0 : 1) < (($1["primary"] as? Bool) == true ? 0 : 1) }
            .compactMap { $0["id"] as? String }
    }

    private func findEvent(calendarID: String, iCalUID: String, token: String) async throws -> [String: Any]? {
        var components = URLComponents(string:
            "https://www.googleapis.com/calendar/v3/calendars/\(pathEscaped(calendarID))/events")!
        components.queryItems = [
            .init(name: "iCalUID", value: iCalUID),
            .init(name: "showDeleted", value: "false"),
            .init(name: "maxResults", value: "5"),
        ]
        let json = try await get(url: components.url!, token: token)
        let items = json["items"] as? [[String: Any]] ?? []
        return items.first
    }

    private func eventURL(calendarID: String, eventID: String) -> URL {
        URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(pathEscaped(calendarID))/events/\(pathEscaped(eventID))")!
    }

    private func patch(calendarID: String, eventID: String, body: [String: Any], token: String) async throws {
        var components = URLComponents(url: eventURL(calendarID: calendarID, eventID: eventID),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "sendUpdates", value: "all")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await send(request)
    }

    private func fetchPrimaryEmail(accessToken: String) async throws -> String? {
        let json = try await get(
            url: URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!,
            token: accessToken
        )
        let items = json["items"] as? [[String: Any]] ?? []
        let primary = items.first(where: { ($0["primary"] as? Bool) == true })
        return primary?["id"] as? String
    }

    // MARK: - URLSession plumbing

    private func get(url: URL, token: String) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        return try await send(request)
    }

    private func postForm(url: String, fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = fields
            .map { "\(formEscaped($0.key))=\(formEscaped($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)
        return try await send(request)
    }

    @discardableResult
    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "GoogleCalendar", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
        if data.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: - Encoding helpers

    private func pathEscaped(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    private func formEscaped(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: - PKCE

    private static func randomCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}

/// One connected Google account as shown in Settings.
struct GoogleAccount: Identifiable, Equatable {
    var id: String { email }
    let email: String
    /// Token revoked / expired or missing a scope: the user must sign in again.
    var needsReconnect = false
    /// When this account's events were last fetched successfully.
    var lastSync: Date?
}

/// OAuth tokens persisted in the Keychain, one item per account.
struct GoogleTokens: Codable {
    var accessToken: String
    var refreshToken: String
    /// When the access token should be treated as expired (already padded).
    var expiry: Date
    var email: String?
}

/// Where per-account token blobs live: the Keychain in the app, memory in tests.
protocol TokenVault {
    func save(_ data: Data, account: String)
    func load(account: String) -> Data?
    func delete(account: String)
}

/// Generic-password Keychain items under one service, keyed by account email.
struct KeychainVault: TokenVault {
    private let service = "com.rc.MenubarCalendar.google"

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func save(_ data: Data, account: String) {
        SecItemDelete(query(account) as CFDictionary)
        var attributes = query(account)
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func load(account: String) -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

/// Reads the Google client id from Info.plist and derives the reversed-client-id
/// redirect used by Google's installed-app OAuth flow.
private enum GoogleConfig {
    // `calendar.events` reads/patches the RSVP; `calendar.calendarlist.readonly`
    // lists calendars (finding where an invitation lives, the account email);
    // `calendar.readonly` reads every selected calendar for the Google source.
    static let scope = "https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/calendar.calendarlist.readonly https://www.googleapis.com/auth/calendar.readonly"

    static var clientID: String? {
        let value = Bundle.main.object(forInfoDictionaryKey: "GoogleOAuthClientID") as? String
        guard let value, !value.isEmpty, !value.hasPrefix("YOUR_") else { return nil }
        return value
    }

    /// `NNNN-xxxx.apps.googleusercontent.com` → `com.googleusercontent.apps.NNNN-xxxx`.
    static func redirectScheme(clientID: String) -> String {
        let suffix = ".apps.googleusercontent.com"
        let core = clientID.hasSuffix(suffix) ? String(clientID.dropLast(suffix.count)) : clientID
        return "com.googleusercontent.apps.\(core)"
    }

    static func redirectURI(clientID: String) -> String {
        "\(redirectScheme(clientID: clientID)):/oauth2redirect"
    }
}
```

- [ ] **Step 5: Update the call sites**

`MenubarCalendarApp.swift`: replace both `GoogleCalendarService` with `GoogleAccountStore`. The type of `@StateObject private var google` and the `GoogleAccountStore()` call change. Nothing else.

`CalendarViewModel.swift`:
- `let google: GoogleCalendarService` → `let google: GoogleAccountStore`
- `init(settings: AppSettings, google: GoogleCalendarService)` → `GoogleAccountStore`
- In `declineEvent(rowID:)`, replace the `if google.isConnected, let uid, !uid.isEmpty { … }` branch with:

```swift
        if google.hasUsableAccount, let uid, !uid.isEmpty {
            Task { @MainActor in
                do {
                    // Any connected account may hold a writable copy (its own
                    // calendar, or one shared into it with edit access).
                    for account in google.accounts where !account.needsReconnect {
                        if try await google.declineEvent(iCalUID: uid, as: account.email) {
                            declinedUIDs.insert(uid)
                            eventsByRowID[rowID] = nil
                            reload()
                            return
                        }
                    }
                    diag("google decline: event not found on a writable calendar, falling back")
                    localRemove(event, rowID: rowID)
                } catch {
                    // A real API failure. Do NOT locally delete — that would
                    // hide the event while leaving the user shown as attending.
                    diag("google decline failed for \(rowID): \(error)")
                    google.reportDeclineFailure(error)
                    NSSound.beep()
                }
            }
        } else {
```

`EventListView.swift`:
- `@EnvironmentObject private var google: GoogleCalendarService` → `GoogleAccountStore`
- In `declineMessage(for:)`, `google.isConnected` → `google.hasUsableAccount`

`SettingsView.swift`:
- `@EnvironmentObject private var google: GoogleCalendarService` → `GoogleAccountStore`
- Replace `googleSection` with:

```swift
    private var googleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Konta Google")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if !google.isConfigured {
                Text("Integracja Google nie jest skonfigurowana w tej wersji aplikacji.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(google.accounts) { account in
                    HStack(spacing: 8) {
                        Image(systemName: account.needsReconnect
                              ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(account.needsReconnect ? .orange : .green)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(account.email)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let caption = accountCaption(account) {
                                Text(caption)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        if account.needsReconnect {
                            Button("Połącz ponownie") { Task { await google.addAccount() } }
                                .disabled(google.isBusy)
                        }
                        Button("Usuń") { google.remove(email: account.email) }
                    }
                }

                Button {
                    Task { await google.addAccount() }
                } label: {
                    if google.isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Dodaj konto Google…", systemImage: "person.crop.circle.badge.plus")
                    }
                }
                .disabled(google.isBusy)

                Text("Odrzucenie wydarzenia przez połączone konto powiadomi organizatora (także dla kalendarzy udostępnionych z prawem edycji). Bez konta odrzucenie tylko usuwa wydarzenie z Twojego widoku.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = google.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func accountCaption(_ account: GoogleAccount) -> String? {
        if account.needsReconnect { return "Wymaga ponownego połączenia" }
        guard let lastSync = account.lastSync else { return nil }
        return "Ostatnia synchronizacja: \(lastSync.formatted(date: .omitted, time: .shortened))"
    }
```

Check that no references to the old type are left: `grep -rn "GoogleCalendarService\|isConnected\|accountEmail ?? \"Połączono" MenubarCalendar` should return nothing.

- [ ] **Step 6: Run the tests to make sure they pass**

Run `GoogleAccountStoreTests`, then "All tests". Expected: `TEST SUCCEEDED`. Then run Build. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Commit**

```bash
git add -A MenubarCalendar MenubarCalendarTests MenubarCalendar.xcodeproj/project.pbxproj
git commit -m "Support several Google accounts with per-account Keychain tokens"
```

---

### Task 4: `EventSource` protocol and `EventKitSource` (behaviour-preserving refactor)

**Files:**
- Create: `MenubarCalendar/EventSource.swift`
- Create: `MenubarCalendar/EventKitSource.swift`
- Modify: `MenubarCalendar/CalendarViewModel.swift` (substantial rewrite: EventKit code moves out)
- Modify: `MenubarCalendar/Models/EventRow.swift` (`canDecline`)
- Modify: `MenubarCalendar/EventListView.swift` (swipe/context-menu gating)

**Interfaces:**
- Consumes: `GoogleAccountStore.accounts`, `.hasUsableAccount`, `.declineEvent(iCalUID:as:)` (Task 3). `AppSettings.isSelected(_:in:)` (Task 1). `CalendarEvent.iCalUID/isEditable/canDecline` (Task 2).
- Produces:
  - `struct CalendarInfo: Identifiable { id: String; title: String; color: Color; isSelectedByDefault: Bool = true }`. This top-level type replaces `CalendarViewModel.CalendarInfo`.
  - `enum SourceStatus: Equatable { ok, loading, noAccess, notConnected, needsReconnect }`
  - `struct EventSnapshot { calendars: [CalendarInfo]; events: [CalendarEvent]; accountEmails: [String]; status: SourceStatus }`, every field defaulted (`[]`, `.loading`).
  - `enum DeclineOutcome { declined, removedLocally, notApplicable }`
  - `@MainActor protocol EventSource: AnyObject { var onChange: (@MainActor () -> Void)? { get set }; var snapshot: EventSnapshot { get }; func start(); func stop(); func refresh(force: Bool); func decline(eventID: String) async throws -> DeclineOutcome }`
  - `enum Diagnostics { static func log(_ message: String) }`
  - `@MainActor final class EventKitSource: EventSource` with `init(settings: AppSettings, google: GoogleAccountStore)`, `func editDraft(eventID: String) -> EventEditDraft?`, `func saveEdit(_ draft: EventEditDraft, eventID: String) -> Bool`
  - `EventRow.canDecline: Bool` (default `false`)
  - `CalendarViewModel.reload()` reads `source.snapshot`.

This task changes no behaviour. The existing tests plus a manual check in macOS Calendar mode are the gate.

- [ ] **Step 1: Create `EventSource.swift`**

Register it first: `scripts/add-xcode-file.py app MenubarCalendar/EventSource.swift`

```swift
import Foundation
import SwiftUI

/// A calendar the user can include or exclude in Settings.
struct CalendarInfo: Identifiable {
    let id: String
    let title: String
    let color: Color
    /// Whether it counts as selected before the user touches the list
    /// (always for macOS calendars; Google's own selection for Google ones).
    var isSelectedByDefault: Bool = true
}

/// Why a source has nothing to show, if it doesn't.
enum SourceStatus: Equatable {
    case ok
    /// No result yet (first fetch in flight, or offline since launch).
    case loading
    /// macOS Calendar access not granted.
    case noAccess
    /// Google source with no accounts connected.
    case notConnected
    /// Google source whose every account must sign in again.
    case needsReconnect
}

/// Everything `CalendarViewModel` renders, as last read from a source.
struct EventSnapshot {
    /// All calendars, selected or not (for the Settings list).
    var calendars: [CalendarInfo] = []
    /// Events of the selected calendars from the start of today to 7 days out,
    /// with the user's own declines already removed.
    var events: [CalendarEvent] = []
    var accountEmails: [String] = []
    var status: SourceStatus = .loading
}

enum DeclineOutcome {
    /// An RSVP reached Google and the organizer is notified. The source already
    /// hides the event.
    case declined
    /// No RSVP was possible, so only the local copy was removed.
    case removedLocally
    /// Nothing could be done (not invited, read-only calendar, event gone).
    case notApplicable
}

/// Where events come from. `CalendarViewModel` holds exactly one at a time,
/// chosen by `AppSettings.dataSource`.
@MainActor
protocol EventSource: AnyObject {
    /// Called whenever `snapshot` may have changed.
    var onChange: (@MainActor () -> Void)? { get set }
    var snapshot: EventSnapshot { get }
    func start()
    func stop()
    /// Ask for fresh data; `force: false` may be skipped if the data is recent.
    func refresh(force: Bool)
    /// Decline the event whose `CalendarEvent.identifier` is `eventID`.
    func decline(eventID: String) async throws -> DeclineOutcome
}

/// Appends to `/private/tmp/mbc_diag.log` — the app's existing debug trail.
enum Diagnostics {
    static func log(_ message: String) {
        let path = "/private/tmp/mbc_diag.log"
        let line = "\(Date()) [pid \(ProcessInfo.processInfo.processIdentifier)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
```

- [ ] **Step 2: Create `EventKitSource.swift`**

Register: `scripts/add-xcode-file.py app MenubarCalendar/EventKitSource.swift`

The code below is moved out of `CalendarViewModel` (`requestAccess`, the body of `reload`, `localRemove`, `isDeclined`, `editDraft`, `saveEdit`, `accountEmail(for:)`, `email(fromParticipantURL:)`, `color(for:)`, `declinedUIDs`). The behaviour stays the same.

```swift
import AppKit
import EventKit
import SwiftUI

/// Events from macOS's calendar database via EventKit — whatever accounts are
/// set up in System Settings → Internet Accounts / Calendar.app. EventKit is
/// queried afresh on every `snapshot` read, so the 30-second tick picks up
/// changes even without `.EKEventStoreChanged`.
@MainActor
final class EventKitSource: EventSource {
    var onChange: (@MainActor () -> Void)?

    private let store = EKEventStore()
    private let settings: AppSettings
    /// Used to send a real "declined" RSVP that notifies the organizer.
    private let google: GoogleAccountStore
    /// The `EKEvent` behind each `CalendarEvent.identifier` of the last
    /// snapshot, so decline/edit act on the exact occurrence on screen —
    /// including a single instance of a recurring event.
    private var eventsByID: [String: EKEvent] = [:]
    private var observer: NSObjectProtocol?

    /// iCal UIDs the user has declined through the Google API. A decline keeps
    /// the event on the server (marked declined) rather than deleting it, so
    /// these are hidden locally until sync catches up. Persisted so they don't
    /// reappear after a restart.
    private var declinedUIDs: Set<String> {
        didSet { UserDefaults.standard.set(Array(declinedUIDs), forKey: "declinedICalUIDs") }
    }

    init(settings: AppSettings, google: GoogleAccountStore) {
        self.settings = settings
        self.google = google
        self.declinedUIDs = Set(UserDefaults.standard.stringArray(forKey: "declinedICalUIDs") ?? [])
    }

    func start() {
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.onChange?() }
        }
        requestAccess()
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    func refresh(force: Bool) {
        onChange?()
    }

    private func requestAccess() {
        let status = EKEventStore.authorizationStatus(for: .event)
        Diagnostics.log("authorizationStatus rawValue=\(status.rawValue)")
        guard status == .notDetermined else {
            onChange?()
            return
        }
        store.requestFullAccessToEvents { [weak self] granted, error in
            Diagnostics.log("requestFullAccessToEvents granted=\(granted) error=\(String(describing: error))")
            Task { @MainActor in self?.onChange?() }
        }
    }

    // MARK: - Snapshot

    var snapshot: EventSnapshot {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            break
        case .notDetermined:
            eventsByID = [:]
            return EventSnapshot(status: .loading)
        default: // .denied, .restricted, .writeOnly
            eventsByID = [:]
            return EventSnapshot(status: .noAccess)
        }

        let cal = Calendar.current
        let now = Date()
        let end = cal.date(byAdding: .day, value: 7, to: now) ?? now

        let allCalendars = store.calendars(for: .event)
        let calendars = allCalendars.map {
            CalendarInfo(id: $0.calendarIdentifier, title: $0.title, color: Self.color(for: $0))
        }
        // Seed the account list from the calendars themselves, so an account
        // with no upcoming meeting is still configurable in Settings.
        var accounts = Set<String>()
        for calendar in allCalendars {
            for candidate in [calendar.source.title, calendar.title] where candidate.contains("@") {
                accounts.insert(candidate)
            }
        }

        let selected = allCalendars.filter { settings.isSelected($0.calendarIdentifier, in: .eventKit) }
        // Empty means the user deselected everything → show nothing (don't fall
        // back to querying all calendars, which `calendars: nil` would do).
        guard !selected.isEmpty else {
            eventsByID = [:]
            return EventSnapshot(calendars: calendars, events: [], accountEmails: accounts.sorted(), status: .ok)
        }

        let predicate = store.predicateForEvents(
            withStart: cal.startOfDay(for: now), end: end, calendars: selected
        )
        var byID: [String: EKEvent] = [:]
        let events = store.events(matching: predicate)
            .filter { !isDeclined($0) }
            .map { ek -> CalendarEvent in
                let id = "\(ek.calendarItemIdentifier)@\(ek.startDate.timeIntervalSince1970)"
                byID[id] = ek
                let editable = ek.calendar.allowsContentModifications
                let event = CalendarEvent(
                    identifier: id,
                    title: ek.title ?? "",
                    startDate: ek.startDate,
                    endDate: ek.endDate,
                    isAllDay: ek.isAllDay,
                    calendarIdentifier: ek.calendar.calendarIdentifier,
                    calendarTitle: ek.calendar.title,
                    url: ek.url,
                    location: ek.location,
                    notes: ek.notes,
                    accountEmail: accountEmail(for: ek),
                    iCalUID: ek.calendarItemExternalIdentifier,
                    isEditable: editable,
                    canDecline: editable
                )
                if let email = event.accountEmail { accounts.insert(email) }
                return event
            }
        eventsByID = byID
        return EventSnapshot(calendars: calendars, events: events, accountEmails: accounts.sorted(), status: .ok)
    }

    // MARK: - Decline

    /// With a usable Google account and an iCal UID, send a real "declined"
    /// RSVP through whichever account holds a writable copy, then hide the
    /// event. Otherwise remove the local copy, which does *not* reliably notify
    /// the organizer. An API error is thrown and nothing is removed, so the user
    /// isn't left hidden-but-still-attending.
    func decline(eventID: String) async throws -> DeclineOutcome {
        guard let event = eventsByID[eventID] else { return .notApplicable }
        if google.hasUsableAccount, let uid = event.calendarItemExternalIdentifier, !uid.isEmpty {
            for account in google.accounts where !account.needsReconnect {
                if try await google.declineEvent(iCalUID: uid, as: account.email) {
                    declinedUIDs.insert(uid)
                    eventsByID[eventID] = nil
                    return .declined
                }
            }
            Diagnostics.log("google decline: event not found on a writable calendar, falling back")
        }
        do {
            try store.remove(event, span: .thisEvent, commit: true)
            eventsByID[eventID] = nil
            return .removedLocally
        } catch {
            Diagnostics.log("remove failed for \(eventID): \(error)")
            return .notApplicable
        }
    }

    /// Whether the current user has declined this event, or we declined it via
    /// the Google API and are hiding it until sync catches up.
    private func isDeclined(_ event: EKEvent) -> Bool {
        if let uid = event.calendarItemExternalIdentifier, declinedUIDs.contains(uid) {
            return true
        }
        return event.attendees?.contains {
            $0.isCurrentUser && $0.participantStatus == .declined
        } ?? false
    }

    // MARK: - Edit

    /// A snapshot of the editable fields, or `nil` if the event is gone or
    /// lives in a read-only calendar.
    func editDraft(eventID: String) -> EventEditDraft? {
        guard let event = eventsByID[eventID],
              event.calendar.allowsContentModifications else { return nil }
        return EventEditDraft(
            title: event.title ?? "",
            isAllDay: event.isAllDay,
            startDate: event.startDate,
            endDate: event.endDate,
            location: event.location ?? "",
            notes: event.notes ?? "",
            hasAttendees: !(event.attendees ?? []).isEmpty
        )
    }

    /// Write an edited draft back and save it. A synced account propagates the
    /// change and notifies guests on the next sync.
    func saveEdit(_ draft: EventEditDraft, eventID: String) -> Bool {
        guard let event = eventsByID[eventID],
              event.calendar.allowsContentModifications else { return false }
        event.title = draft.title
        event.isAllDay = draft.isAllDay
        event.startDate = draft.startDate
        event.endDate = draft.endDate
        event.location = draft.location.isEmpty ? nil : draft.location
        event.notes = draft.notes.isEmpty ? nil : draft.notes
        do {
            try store.save(event, span: .thisEvent, commit: true)
            return true
        } catch {
            Diagnostics.log("save failed for \(eventID): \(error)")
            return false
        }
    }

    // MARK: - Helpers

    /// Best guess at which account an event belongs to: the "current user"
    /// attendee's address, else the calendar's account / title if it's an email.
    private func accountEmail(for event: EKEvent) -> String? {
        if let attendees = event.attendees {
            for participant in attendees where participant.isCurrentUser {
                if let email = Self.email(fromParticipantURL: participant.url) {
                    return email
                }
            }
        }
        let sourceTitle = event.calendar.source.title
        if sourceTitle.contains("@") { return sourceTitle }
        if event.calendar.title.contains("@") { return event.calendar.title }
        return nil
    }

    static func email(fromParticipantURL url: URL) -> String? {
        guard url.scheme?.lowercased() == "mailto" else { return nil }
        let email = url.absoluteString.dropFirst("mailto:".count)
        return email.isEmpty ? nil : String(email)
    }

    private static func color(for calendar: EKCalendar) -> Color {
        if let cg = calendar.cgColor {
            return Color(cgColor: cg)
        }
        return .gray
    }
}
```

- [ ] **Step 3: Rewrite the top half of `CalendarViewModel.swift`**

Keep everything from `// MARK: - Meeting hot key` through `openMeetingURL` exactly as it is. Replace everything **above** that mark with the code below. Delete the old `// MARK: - Swipe actions` section through the end of `email(fromParticipantURL:)`, and add the new swipe-actions section shown below at the end of the class.

```swift
import AppKit
import Combine
import SwiftUI

/// Turns the active `EventSource`'s snapshot into the menu-bar label and the
/// pop-over list, runs the 30-second countdown timer, and routes the swipe
/// actions and meeting hot key (PRD §6). Knows nothing about EventKit or the
/// Google API — see `EventKitSource` / `GoogleAPISource`.
@MainActor
final class CalendarViewModel: ObservableObject {
    /// Text shown in the menu bar, e.g. `Standup… in 27m`.
    @Published var menuBarTitle: String = "…"
    /// The upcoming events shown in the pop-over, grouped into the next 3 days.
    @Published var sections: [DaySection] = []
    /// True when the user has denied (or not granted) calendar access.
    @Published var accessDenied: Bool = false
    /// Why the active source has nothing to show, if it doesn't.
    @Published private(set) var sourceStatus: SourceStatus = .loading
    /// All calendars of the active source, for the settings picker.
    @Published private(set) var availableCalendars: [CalendarInfo] = []
    /// Account emails seen across the visible events and calendars, so Settings
    /// can offer a Chrome profile per account.
    @Published private(set) var accountEmails: [String] = []
    /// The event currently shown in the menu bar (target of the meeting hot key).
    @Published private(set) var selectedEvent: CalendarEvent?

    private let settings: AppSettings
    /// Google accounts: shared with Settings, used by both sources to decline.
    let google: GoogleAccountStore
    private var source: EventSource
    /// Joinable meeting link (and its account) per row id, for tap/hover "Join".
    private var meetingByRowID: [String: (url: URL, accountEmail: String?)] = [:]
    private let hotKey = HotKeyManager()
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    /// A Polish-locale calendar so day/time labels match the PRD copy.
    private var calendar: Calendar {
        var cal = Calendar.current
        cal.locale = Locale(identifier: "pl_PL")
        return cal
    }

    /// True when hosted by the XCTest runner — skip sources and timers.
    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    init(settings: AppSettings, google: GoogleAccountStore) {
        self.settings = settings
        self.google = google
        self.source = EventKitSource(settings: settings, google: google)

        // Don't touch EventKit / timers when hosted by the unit-test runner.
        guard !Self.isRunningTests else { return }

        source.onChange = { [weak self] in self?.reload() }

        // Reload + re-register the hot key whenever a setting changes
        // (all-day toggle, calendar selection, or the shortcut itself).
        settings.objectWillChange
            .sink { [weak self] in
                Task { @MainActor in
                    self?.reload()
                    self?.updateHotKey()
                }
            }
            .store(in: &cancellables)

        source.start()
        startTimer()
        updateHotKey()
    }

    // MARK: - Refresh

    private func startTimer() {
        timer?.invalidate()
        // PRD §3.1: refresh the countdown at least every 30 seconds.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    /// Recompute the label + list from the active source's snapshot.
    func reload() {
        let snapshot = source.snapshot
        sourceStatus = snapshot.status
        accessDenied = snapshot.status == .noAccess
        availableCalendars = snapshot.calendars
        accountEmails = snapshot.accountEmails
        guard snapshot.status == .ok else {
            showEmpty(for: snapshot.status)
            return
        }

        let cal = calendar
        let now = Date()
        let events = snapshot.events
        var meetingMap: [String: (url: URL, accountEmail: String?)] = [:]
        for event in events {
            if let url = EventLinkExtractor.meetingURL(for: event) {
                meetingMap[event.identifier] = (url, event.accountEmail)
            }
        }
        meetingByRowID = meetingMap

        let colorByCalendar = Dictionary(
            snapshot.calendars.map { ($0.id, $0.color) },
            uniquingKeysWith: { first, _ in first }
        )

        let selection = EventLogic.menuBarSelection(
            events, now: now, showAllDay: settings.showAllDay, calendar: cal
        )
        let groups = EventLogic.daySections(
            events, now: now, showAllDay: settings.showAllDay, calendar: cal
        )
        sections = groups.map { group in
            DaySection(
                id: group.dateLabel,
                title: group.title,
                dateLabel: group.dateLabel,
                emptyMessage: group.emptyMessage,
                rows: group.events.map { event in
                    EventRow(
                        id: event.identifier,
                        title: EventLogic.listTitle(event.title),
                        startTime: EventLogic.timeString(for: event.startDate, calendar: cal),
                        endTime: EventLogic.timeString(for: event.endDate, calendar: cal),
                        calendarColor: colorByCalendar[event.calendarIdentifier] ?? .gray,
                        isAllDay: event.isAllDay,
                        isEditable: event.isEditable,
                        canDecline: event.canDecline,
                        hasMeeting: meetingMap[event.identifier] != nil,
                        isNext: event.identifier == selection?.identifier,
                        isInProgress: EventLogic.isInProgress(event, now: now)
                    )
                }
            )
        }
        selectedEvent = selection
        menuBarTitle = EventLogic.menuBarTitle(
            events, now: now, showAllDay: settings.showAllDay, calendar: cal
        )
    }

    private func showEmpty(for status: SourceStatus) {
        sections = []
        selectedEvent = nil
        meetingByRowID = [:]
        switch status {
        case .noAccess: menuBarTitle = "No access"
        case .notConnected: menuBarTitle = "Connect Google"
        case .needsReconnect: menuBarTitle = "Reconnect Google"
        case .loading, .ok: menuBarTitle = "…"
        }
    }
```

New swipe-actions section at the end of the class (after `openMeetingURL`):

```swift
    // MARK: - Swipe actions (decline / edit)

    /// Decline attendance through the active source (a real RSVP where
    /// possible). On an API failure nothing is hidden and the error is shown.
    func declineEvent(rowID: String) {
        Task { @MainActor in
            do {
                switch try await source.decline(eventID: rowID) {
                case .declined, .removedLocally:
                    reload()
                case .notApplicable:
                    NSSound.beep()
                }
            } catch {
                Diagnostics.log("decline failed for \(rowID): \(error)")
                google.reportDeclineFailure(error)
                NSSound.beep()
            }
        }
    }

    /// Editable fields for the row's event; only the macOS Calendar source
    /// supports editing.
    func editDraft(rowID: String) -> EventEditDraft? {
        (source as? EventKitSource)?.editDraft(eventID: rowID)
    }

    @discardableResult
    func saveEdit(_ draft: EventEditDraft, rowID: String) -> Bool {
        guard let eventKit = source as? EventKitSource,
              eventKit.saveEdit(draft, eventID: rowID) else {
            NSSound.beep()
            return false
        }
        reload()
        return true
    }
}
```

If anything else referenced `CalendarViewModel.email(fromParticipantURL:)`, point it at `EventKitSource.email(fromParticipantURL:)`. Check with `grep -rn "fromParticipantURL" MenubarCalendar MenubarCalendarTests`.

- [ ] **Step 4: Split the row gating**

`Models/EventRow.swift`: change the `isEditable` doc and add `canDecline` after it:

```swift
    /// Whether the Edit action is offered (writable calendar, macOS Calendar source).
    let isEditable: Bool
    /// Whether the Decline action is offered.
    var canDecline: Bool = false
```

Update the `EventEditDraft` doc so it no longer names `CalendarViewModel`'s internals; it is still produced by `CalendarViewModel.editDraft(rowID:)`, so that wording stays.

`EventListView.swift`, `.swipeActions` block: replace the single `if row.isEditable { … }` with:

```swift
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if row.canDecline {
                                    Button {
                                        withAnimation(.snappy(duration: 0.25)) { pendingDecline = row }
                                    } label: {
                                        Image(systemName: "calendar.badge.minus")
                                    }
                                    .tint(.red)
                                }
                                if row.isEditable {
                                    Button {
                                        beginEditing(row)
                                    } label: {
                                        Image(systemName: "pencil")
                                    }
                                    .tint(.blue)
                                }
                            }
```

and in `.contextMenu`:

```swift
                                if row.isEditable {
                                    Button("Edit…") { beginEditing(row) }
                                }
                                if row.canDecline {
                                    Button("Decline…", role: .destructive) {
                                        withAnimation(.snappy(duration: 0.25)) { pendingDecline = row }
                                    }
                                }
```

- [ ] **Step 5: Build and run all tests**

Run Build, then "All tests". Expected: `BUILD SUCCEEDED` and `TEST SUCCEEDED`. Also `grep -n "import EventKit" MenubarCalendar/CalendarViewModel.swift` should print nothing.

- [ ] **Step 6: Manual check in macOS Calendar mode**

Make sure the data source is EventKit: `defaults write com.tonik.MenubarCalendar dataSource eventKit`. Launch `/tmp/mc-build/Build/Products/Debug/MenubarCalendar.app`. Check that:
- the menu-bar countdown and the pop-over list match before the refactor;
- the Decline and Edit swipes still appear on writable events;
- the hot key still opens the next meeting.

- [ ] **Step 7: Commit**

```bash
git add MenubarCalendar MenubarCalendar.xcodeproj/project.pbxproj
git commit -m "Move EventKit reading into an EventSource behind the view model"
```

---

### Task 5: `GoogleAPISource`: polling the Google Calendar API

**Files:**
- Create: `MenubarCalendar/GoogleAPISource.swift`
- Test: `MenubarCalendarTests/GoogleAPISourceTests.swift` (new)

**Interfaces:**
- Consumes:
  - `EventSource`, `EventSnapshot`, `CalendarInfo`, `SourceStatus`, `DeclineOutcome`, `Diagnostics` (Task 4)
  - `GoogleAccountStore.accounts`, `.hasUsableAccount`, `.getJSON(_:as:)`, `.recordSync(email:)`, `.declineInstance(calendarID:eventID:as:)`, `isAuthFailure`, `isRateLimited` (Task 3)
  - `GoogleEventMapper` and its types (Task 2)
  - `AppSettings.isSelected(_:in:default:)`, `$selectedGoogleCalendarIDs` (Task 1)
- Produces:
  - `struct PollSchedule { static baseInterval = 120, maxInterval = 600, freshness = 15; private(set) var interval: TimeInterval; mutating func recordSuccess(); mutating func recordThrottled(); static func isFresh(lastSuccess: Date?, now: Date) -> Bool }`
  - `@MainActor final class GoogleAPISource: EventSource` with `init(accounts: GoogleAccountStore, settings: AppSettings)`, `static func window(now: Date, calendar: Calendar = .current) -> (start: Date, end: Date)`, `static func eventsURL(calendarID: String, window: (start: Date, end: Date)) -> URL`
  - `extension Color { init?(hex: String?) }`

- [ ] **Step 1: Write the failing tests**

Create `MenubarCalendarTests/GoogleAPISourceTests.swift`:

```swift
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
```

Register both files:

```bash
scripts/add-xcode-file.py app MenubarCalendar/GoogleAPISource.swift
scripts/add-xcode-file.py tests MenubarCalendarTests/GoogleAPISourceTests.swift
```

Create `MenubarCalendar/GoogleAPISource.swift` containing only `import Foundation`.

- [ ] **Step 2: Run the tests to make sure they fail**

Run `GoogleAPISourceTests`. Expected: compile failure, `cannot find 'PollSchedule' in scope`.

- [ ] **Step 3: Implement `GoogleAPISource.swift`**

```swift
import AppKit
import Combine
import Foundation
import Network
import SwiftUI

/// When to poll: every 2 minutes, doubling after a throttled poll up to 10
/// minutes, back to 2 after a good one. Pure, so it is unit-tested.
struct PollSchedule {
    static let baseInterval: TimeInterval = 120
    static let maxInterval: TimeInterval = 600
    /// Opening the pop-over within this long of a good fetch doesn't refetch.
    static let freshness: TimeInterval = 15

    private(set) var interval: TimeInterval = baseInterval

    mutating func recordSuccess() { interval = Self.baseInterval }
    mutating func recordThrottled() { interval = min(interval * 2, Self.maxInterval) }

    static func isFresh(lastSuccess: Date?, now: Date) -> Bool {
        guard let lastSuccess else { return false }
        return now.timeIntervalSince(lastSuccess) < freshness
    }
}

/// Events fetched straight from the Google Calendar API for every connected
/// account — no Calendar.app, no macOS Internet Accounts, no backend.
///
/// Polls a fixed window (start of today → now + 7 days) every
/// `PollSchedule.interval`, and also on wake, when the network comes back,
/// when the pop-over opens (unless fresh), and when accounts or the calendar
/// selection change. Only one fetch runs at a time; a trigger during a fetch
/// queues exactly one follow-up. The last good result per account is kept
/// across network failures so the countdown keeps working offline.
@MainActor
final class GoogleAPISource: EventSource {
    var onChange: (@MainActor () -> Void)?
    private(set) var snapshot = EventSnapshot()

    private struct AccountResult {
        var calendars: [GoogleCalendarEntry]
        var events: [MappedGoogleEvent]
    }

    private let accounts: GoogleAccountStore
    private let settings: AppSettings
    private var results: [String: AccountResult] = [:]
    private var eventsByID: [String: MappedGoogleEvent] = [:]
    private var schedule = PollSchedule()
    private var lastSuccess: Date?
    private var isRunning = false
    private var isFetching = false
    private var refetchQueued = false
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    private var networkWasDown = false
    private var cancellables = Set<AnyCancellable>()

    init(accounts: GoogleAccountStore, settings: AppSettings) {
        self.accounts = accounts
        self.settings = settings
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true

        // Accounts added/removed or reconnected → fetch now.
        accounts.$accounts
            .map { $0.map { "\($0.email)|\($0.needsReconnect)" } }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.refresh(force: true) } }
            .store(in: &cancellables)

        // A newly ticked calendar has nothing cached yet → fetch now.
        settings.$selectedGoogleCalendarIDs
            .dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.refresh(force: true) } }
            .store(in: &cancellables)

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh(force: true) }
        }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let isUp = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(isUp: isUp) }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor

        rebuildSnapshot()
        onChange?()
        refresh(force: true)
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        cancellables.removeAll()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    func refresh(force: Bool) {
        guard isRunning else { return }
        if !force && PollSchedule.isFresh(lastSuccess: lastSuccess, now: Date()) { return }
        guard !isFetching else {
            refetchQueued = true
            return
        }
        Task { await fetchAll() }
    }

    private func networkChanged(isUp: Bool) {
        if isUp && networkWasDown { refresh(force: true) }
        networkWasDown = !isUp
    }

    // MARK: - Fetching

    private func fetchAll() async {
        isFetching = true
        let window = Self.window(now: Date())
        let emails = accounts.accounts.filter { !$0.needsReconnect }.map(\.email)
        // Forget accounts that were removed or must reconnect.
        results = results.filter { emails.contains($0.key) }

        var throttled = false
        var anySuccess = false
        for email in emails {
            do {
                results[email] = try await fetchAccount(email, window: window)
                accounts.recordSync(email: email)
                anySuccess = true
            } catch {
                Diagnostics.log("google fetch failed for \(email): \(error)")
                if GoogleAccountStore.isRateLimited(error) || Self.isServerError(error) {
                    throttled = true
                }
                // The store already marked an auth failure for reconnect; drop
                // that account's events. Other failures keep the last good result.
                if GoogleAccountStore.isAuthFailure(error) {
                    results[email] = nil
                }
            }
        }
        if throttled {
            schedule.recordThrottled()
        } else if anySuccess {
            schedule.recordSuccess()
        }
        if anySuccess { lastSuccess = Date() }
        isFetching = false

        rebuildSnapshot()
        onChange?()
        scheduleNextPoll()
        if refetchQueued {
            refetchQueued = false
            refresh(force: true)
        }
    }

    private func fetchAccount(_ email: String, window: (start: Date, end: Date)) async throws -> AccountResult {
        let calendars = try await pagedItems(Self.calendarListURL, as: email)
            .compactMap { GoogleEventMapper.calendar(from: $0, accountEmail: email) }
        var events: [MappedGoogleEvent] = []
        for calendar in calendars where isSelected(calendar) {
            do {
                let items = try await pagedItems(Self.eventsURL(calendarID: calendar.calendarID, window: window), as: email)
                events += items.compactMap { GoogleEventMapper.event(from: $0, calendar: calendar) }
            } catch where Self.isPerCalendarError(error) {
                // e.g. 404 for a calendar unsubscribed since the list call: skip it.
                Diagnostics.log("google fetch skipped \(calendar.key): \(error)")
            }
        }
        return AccountResult(calendars: calendars, events: events)
    }

    /// Every `items` entry across `nextPageToken` pages.
    private func pagedItems(_ url: URL, as email: String) async throws -> [[String: Any]] {
        var items: [[String: Any]] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            if let pageToken {
                components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "pageToken", value: pageToken)]
            }
            let json = try await accounts.getJSON(components.url!, as: email)
            items += json["items"] as? [[String: Any]] ?? []
            pageToken = json["nextPageToken"] as? String
        } while pageToken != nil
        return items
    }

    private func scheduleNextPoll() {
        timer?.invalidate()
        guard isRunning else { return }
        timer = Timer.scheduledTimer(withTimeInterval: schedule.interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh(force: true) }
        }
    }

    // MARK: - Snapshot

    private func isSelected(_ calendar: GoogleCalendarEntry) -> Bool {
        settings.isSelected(calendar.key, in: .google, default: calendar.isSelectedInGoogle)
    }

    private func rebuildSnapshot() {
        let order = accounts.accounts.map(\.email)
        let ordered = order.compactMap { results[$0] }
        let calendars = ordered.flatMap(\.calendars)
        let selectedKeys = Set(calendars.filter(isSelected).map(\.key))
        // Filter again so un-ticking a calendar hides it before the next fetch.
        let mapped = GoogleEventMapper.dedupe(ordered.flatMap(\.events))
            .filter { selectedKeys.contains($0.event.calendarIdentifier) }
        eventsByID = Dictionary(mapped.map { ($0.event.identifier, $0) }, uniquingKeysWith: { first, _ in first })

        let multipleAccounts = order.count > 1
        snapshot = EventSnapshot(
            calendars: calendars.map { entry in
                CalendarInfo(
                    id: entry.key,
                    // Same-named calendars ("Holidays") from two accounts need telling apart.
                    title: multipleAccounts && entry.title != entry.accountEmail
                        ? "\(entry.title) — \(entry.accountEmail)" : entry.title,
                    color: Color(hex: entry.colorHex) ?? .gray,
                    isSelectedByDefault: entry.isSelectedInGoogle
                )
            },
            events: mapped.map(\.event).sorted { $0.startDate < $1.startDate },
            accountEmails: order,
            status: currentStatus()
        )
    }

    private func currentStatus() -> SourceStatus {
        if accounts.accounts.isEmpty { return .notConnected }
        if !accounts.hasUsableAccount { return .needsReconnect }
        return results.isEmpty ? .loading : .ok
    }

    // MARK: - Decline

    /// Decline the exact occurrence through the account that owns it, then hide
    /// it right away; the next poll returns it as declined and the mapper drops it.
    func decline(eventID: String) async throws -> DeclineOutcome {
        guard let item = eventsByID[eventID], item.event.canDecline,
              let email = item.event.accountEmail else { return .notApplicable }
        guard try await accounts.declineInstance(calendarID: item.calendarID, eventID: item.eventID, as: email) else {
            return .notApplicable
        }
        for key in results.keys {
            results[key]?.events.removeAll { $0.event.identifier == eventID }
        }
        rebuildSnapshot()
        return .declined
    }

    // MARK: - Requests

    static let calendarListURL = URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!

    static func window(now: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        (calendar.startOfDay(for: now), now.addingTimeInterval(7 * 24 * 3600))
    }

    static func eventsURL(calendarID: String, window: (start: Date, end: Date)) -> URL {
        let escaped = calendarID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? calendarID
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/\(escaped)/events")!
        components.queryItems = [
            .init(name: "timeMin", value: GoogleEventMapper.rfc3339(window.start)),
            .init(name: "timeMax", value: GoogleEventMapper.rfc3339(window.end)),
            .init(name: "singleEvents", value: "true"),
            .init(name: "orderBy", value: "startTime"),
            .init(name: "showDeleted", value: "false"),
            .init(name: "maxResults", value: "250"),
        ]
        return components.url!
    }

    private static func isServerError(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == "GoogleCalendar" && ns.code >= 500
    }

    /// A 4xx about one calendar (not auth, not throttling) — skip that calendar
    /// instead of failing the whole account.
    private static func isPerCalendarError(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == "GoogleCalendar" && (400..<500).contains(ns.code)
            && !GoogleAccountStore.isAuthFailure(error) && !GoogleAccountStore.isRateLimited(error)
    }
}

extension Color {
    /// `#rrggbb` → Color; `nil` for anything else.
    init?(hex: String?) {
        guard let hex, hex.hasPrefix("#"), hex.count == 7,
              let value = Int(hex.dropFirst(), radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
```

- [ ] **Step 4: Run the tests to make sure they pass**

Run `GoogleAPISourceTests`, then "All tests". Expected: `TEST SUCCEEDED`.

If `testEventsURL`'s `percentEncodedPath` assertion fails only because `URLComponents` re-encodes `%2E` as a literal `.`, compare the decoded path instead: `components.path == "/calendar/v3/calendars/team@group.calendar.google.com/events"`. Keep the other assertions.

- [ ] **Step 5: Commit**

```bash
git add MenubarCalendar/GoogleAPISource.swift MenubarCalendarTests/GoogleAPISourceTests.swift \
  MenubarCalendar.xcodeproj/project.pbxproj
git commit -m "Poll the Google Calendar API as an event source"
```

---

### Task 6: Switch sources from Settings and show Google states in the pop-over

**Files:**
- Modify: `MenubarCalendar/CalendarViewModel.swift`
- Modify: `MenubarCalendar/SettingsView.swift`
- Modify: `MenubarCalendar/EventListView.swift`
- Modify: `MenubarCalendar/MenubarCalendarApp.swift`

**Interfaces:**
- Consumes: everything above.
- Produces:
  - `CalendarViewModel.popoverDidOpen()`
  - `CalendarViewModel.declineNotifiesOrganizer: Bool`
  - `struct ConnectGoogleView: View` (`needsReconnect: Bool`, `onOpenSettings: () -> Void`)

- [ ] **Step 1: Source switching in `CalendarViewModel`**

In `init`, replace `self.source = EventKitSource(settings: settings, google: google)` with:

```swift
        self.source = Self.makeSource(settings.dataSource, settings: settings, google: google)
```

After the existing `settings.objectWillChange` sink in `init`, add:

```swift
        // Data source switched in Settings → swap the source.
        settings.$dataSource
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] kind in
                Task { @MainActor in self?.switchSource(to: kind) }
            }
            .store(in: &cancellables)
```

Add under `// MARK: - Refresh`:

```swift
    private static func makeSource(
        _ kind: DataSource, settings: AppSettings, google: GoogleAccountStore
    ) -> EventSource {
        switch kind {
        case .google: GoogleAPISource(accounts: google, settings: settings)
        case .eventKit: EventKitSource(settings: settings, google: google)
        }
    }

    private func switchSource(to kind: DataSource) {
        source.onChange = nil
        source.stop()
        source = Self.makeSource(kind, settings: settings, google: google)
        source.onChange = { [weak self] in self?.reload() }
        source.start()
        reload()
    }

    /// The pop-over just opened: fetch unless the data is only seconds old.
    func popoverDidOpen() {
        source.refresh(force: false)
    }

    /// Whether Decline reaches the organizer — always in Google mode (or it
    /// fails visibly); in macOS Calendar mode only with a connected account.
    var declineNotifiesOrganizer: Bool {
        settings.dataSource == .google || google.hasUsableAccount
    }
```

- [ ] **Step 2: Settings: data-source picker and per-source calendar list**

In `SettingsView.body`, put a new section first inside the inner `VStack`:

```swift
                    sourceSection
                    Divider()
                    googleSection
```

Add:

```swift
    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Źródło danych")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Picker("", selection: $settings.dataSource) {
                Text("Google (bezpośrednio)").tag(DataSource.google)
                Text("Kalendarz macOS").tag(DataSource.eventKit)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(settings.dataSource == .google
                 ? "Wydarzenia są pobierane z Google co 2 minuty — aplikacja Kalendarz nie jest potrzebna."
                 : "Wydarzenia pochodzą z kont skonfigurowanych w macOS (Ustawienia systemowe → Konta internetowe).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
```

In `calendarsSection`, make the toggle follow the active source and each calendar's default:

```swift
                ForEach(viewModel.availableCalendars) { calendar in
                    Toggle(isOn: Binding(
                        get: {
                            settings.isSelected(calendar.id, in: settings.dataSource,
                                                default: calendar.isSelectedByDefault)
                        },
                        set: { newValue in
                            settings.setSelected(
                                calendar.id,
                                selected: newValue,
                                in: settings.dataSource,
                                currentlySelected: viewModel.availableCalendars
                                    .filter {
                                        settings.isSelected($0.id, in: settings.dataSource,
                                                            default: $0.isSelectedByDefault)
                                    }
                                    .map(\.id)
                            )
                        }
                    )) {
```

(The `HStack` label inside stays the same.)

- [ ] **Step 3: Pop-over: connect state, refresh on open, decline copy**

In `EventListView`:
- Remove `@EnvironmentObject private var google: GoogleAccountStore`. It isn't needed any more.
- Add `.onAppear { viewModel.popoverDidOpen() }` after `.frame(width: 340)` on the root `ZStack` in `body`.
- In `declineMessage(for:)`, replace `google.hasUsableAccount` with `viewModel.declineNotifiesOrganizer`.
- Replace `content` with:

```swift
    @ViewBuilder
    private var content: some View {
        if viewModel.accessDenied {
            AccessDeniedView()
                .padding(16)
        } else if viewModel.sourceStatus == .notConnected || viewModel.sourceStatus == .needsReconnect {
            ConnectGoogleView(
                needsReconnect: viewModel.sourceStatus == .needsReconnect,
                onOpenSettings: { withAnimation(nav) { showingSettings = true } }
            )
            .padding(16)
        } else if viewModel.sections.isEmpty {
            emptyState
        } else {
            eventList
        }
    }
```

Add next to `AccessDeniedView`:

```swift
/// Shown in Google mode when no account can fetch events.
struct ConnectGoogleView: View {
    let needsReconnect: Bool
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(needsReconnect ? "Reconnect Google" : "Connect a Google account",
                  systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.headline)
            Text(needsReconnect
                 ? "Google needs you to sign in again before events can be fetched."
                 : "Events come straight from Google Calendar. Add an account in Settings, or switch the data source to macOS Calendar.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings", action: onOpenSettings)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
```

`MenubarCalendarApp.swift`: since `EventListView` no longer reads `google`, keep `.environmentObject(google)`, because `SettingsView` (shown inside it) still does.

- [ ] **Step 4: App wiring: decide the first-launch source**

In `MenubarCalendarApp.swift` add `import EventKit` and change the settings line in `init`:

```swift
        // Someone who already granted calendar access was using the macOS
        // Calendar source; keep them on it until they switch in Settings.
        let settings = AppSettings(
            isExistingInstall: EKEventStore.authorizationStatus(for: .event) == .fullAccess
        )
```

- [ ] **Step 5: Build and run all tests**

Run Build, then "All tests". Expected: `BUILD SUCCEEDED`, `TEST SUCCEEDED`.

- [ ] **Step 6: Manual check, Google mode**

1. `defaults delete com.tonik.MenubarCalendar dataSource; defaults write com.tonik.MenubarCalendar dataSource google`, then launch the Debug build.
2. With the migrated account, expect "Reconnect Google" in the menu bar (its token lacks `calendar.readonly`). In Settings, that account shows "Wymaga ponownego połączenia". Click "Połącz ponownie" and sign in. Events should appear within a few seconds.
3. "Dodaj konto Google…" → sign in to the second account. Its events merge in, and a meeting you're invited to on both accounts shows once.
4. Change an event's time on calendar.google.com. The pop-over shows the change within about 2 minutes, or right away when you reopen it after 15 s.
5. Turn Wi-Fi off. The countdown keeps ticking and the events stay. Turn Wi-Fi back on: a fetch happens (watch `/private/tmp/mbc_diag.log` for errors).
6. Swipe-decline an invitation. It disappears, and the organizer gets the decline email. Edit is not offered.
7. Hot key / Join opens the meeting in the right Chrome profile for each account. Verify as in the [[verifying-chrome-profile-routing]] memory: check the singleton socket and per-profile History, don't eyeball it.
8. Switch Settings → "Kalendarz macOS". The list comes from EventKit with its old calendar ticks intact. Switch back: the Google ticks are intact too.

- [ ] **Step 7: Commit**

```bash
git add MenubarCalendar
git commit -m "Let Settings switch between Google API and macOS Calendar sources"
```

---

### Task 7: Documentation

**Files:**
- Modify: `README.md`
- Modify: `PRD.md` (§ on the calendar source, one paragraph)

- [ ] **Step 1: README**

Add a `## Data source` section after "Build & run":

```markdown
## Data source

Settings → **Źródło danych** picks where events come from — one or the other,
never both:

- **Google (bezpośrednio)** — the app polls the Google Calendar API itself for
  every account connected under **Konta Google**: every 2 minutes, on wake,
  when the network returns, and when the pop-over opens (unless the data is
  under 15 s old). It fetches today through the next 7 days. No Calendar.app or
  macOS Internet Accounts needed. Offline, the last fetched events stay and the
  countdown keeps running. Rate limits / server errors back off up to 10 min.
  Editing events isn't available in this mode; Decline is (through the account
  that owns the event).
- **Kalendarz macOS** — EventKit, i.e. whatever accounts macOS syncs. Fresh
  installs start on Google; installs that had already granted calendar access
  stay here until switched.

Calendar ticks are remembered per source. In Google mode a calendar starts
ticked if it's shown in Google Calendar's own sidebar.
```

Update the "Global shortcut" section's account-detection step 1: in Google mode, the account is the one the event was fetched through. Replace any remaining mention of a single connected Google account ("It authenticates one Google account…" or the decline notes) with the multi-account wording. Find them with `grep -n "Google" README.md`.

- [ ] **Step 2: PRD**

In `PRD.md`, next to `- **Kalendarz:** EventKit (EKEventStore)`, add: `lub Google Calendar API (wybór w Ustawieniach — patrz docs/superpowers/specs/2026-10-02-google-api-event-source-design.md)`.

- [ ] **Step 3: Final full verification**

Run Build and "All tests". Expected: `BUILD SUCCEEDED`, `TEST SUCCEEDED`, with no new warnings from the files this plan touched.

- [ ] **Step 4: Commit**

```bash
git add README.md PRD.md
git commit -m "Document the Google API data source"
```
