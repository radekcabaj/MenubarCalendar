# Menubar Calendar

A native macOS menu-bar app (no window, no Dock icon) that shows your next
upcoming calendar event with a live countdown, and a pop-over with the next few
events. Built per [`PRD.md`](PRD.md).

Example menu-bar label: `Standup… in 27m`

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15+ (developed with Xcode 26.5, Swift 5 language mode)

## Build & run

Open in Xcode and press **Run** (⌘R):

```sh
open MenubarCalendar.xcodeproj
```

The scheme signs with the `com.tonik.MenubarCalendar` bundle ID. In
**Signing & Capabilities** pick your team so the code signature is stable — this
keeps the calendar permission grant from being re-requested after each rebuild.

Or from the command line. Note the `-derivedDataPath` outside the project —
building inside a Dropbox/iCloud-synced folder stamps files with extended
attributes that `codesign` rejects ("resource fork … not allowed"):

```sh
# Build
xcodebuild -project MenubarCalendar.xcodeproj -scheme MenubarCalendar \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/mc-build build

# Run the tests
xcodebuild -project MenubarCalendar.xcodeproj -scheme MenubarCalendar \
  -destination 'platform=macOS' -derivedDataPath /tmp/mc-build test
```

(Xcode's own builds use `~/Library/Developer/Xcode/DerivedData`, so the GUI is
unaffected.)

## Global shortcut — open the next meeting

A system-wide hot key (default **⌃⌥⌘M**, configurable in Settings) opens the
meeting link of the event currently shown in the menu bar. The link is taken
from the event's URL field, or found in its location / notes (preferring Meet /
Zoom / Teams / …). If the event has no link, the Calendar app opens instead.

Implemented with Carbon `RegisterEventHotKey` — works globally with **no**
Accessibility permission and no third-party dependency.

### Opening in the right browser and Google account

Meeting links always open in the **system default browser** — whatever you've
set in System Settings (Safari, Arc, Dia, Chrome, …). There is no browser
setting in the app.

For Google links (`*.google.com`, so Meet and Calendar included) the event's own
account is pinned with `authuser=<email>`, so the link lands on the right
identity when the browser is signed into several accounts:

1. The event's account is taken from the "current user" attendee's address, or
   the calendar's account / title when it's an email (e.g. `radek@tonik.com`).
2. `authuser=<email>` is added to the URL (replacing any existing value).

Non-Google links open untouched, as do events with no resolvable account. The
`authuser` rewrite is a pure function in `EventLinkExtractor` and is unit-tested.

On first launch the app requests **full calendar access**. If you deny it, the
pop-over shows a message with a shortcut to System Settings → Privacy →
Calendars.

## Project layout

```
MenubarCalendar/
  MenubarCalendarApp.swift   @main + MenuBarExtra (.window style)
  CalendarViewModel.swift    EventKit store, 30s timer, published UI state, hot key
  EventListView.swift        Pop-over: event list, footer, animated expand
  SettingsView.swift         All-day, launch-at-login, shortcut, calendar picker
  ShortcutRecorder.swift     Click-to-record control for the meeting hot key
  AppSettings.swift          UserDefaults: calendars, all-day, hot key
  LoginItemManager.swift     SMAppService launch-at-login wrapper
  HotKeyManager.swift        Carbon global hot key (RegisterEventHotKey)
  EventLogic.swift           Pure selection/formatting logic (unit-tested)
  EventLinkExtractor.swift   Pure meeting-link extraction + `authuser` rewrite (unit-tested)
  Models/
    CalendarEvent.swift      Value type decoupled from EventKit
    EventRow.swift           Pre-formatted list row
Config/
  Info.plist                 LSUIElement, NSCalendarsFullAccessUsageDescription
MenubarCalendarTests/
  EventLogicTests.swift            30 tests: countdown / all-day / selection
  EventLinkExtractorTests.swift    10 tests: meeting-link extraction, authuser rewrite
```

## Notes on interpretation

- **Menu-bar selection** (PRD §3.4 / §4.4): the label shows the *nearest event by
  day*; within the same day a timed event outranks an all-day one (all-day is the
  "background of the day"). So an all-day event *today* beats a timed event
  *tomorrow* — matching the "nearest upcoming event" goal. See
  `EventLogic.menuBarSelection`.
- **Launch-at-login** state is read live from `SMAppService.status` (the source
  of truth) rather than mirrored in `UserDefaults`, so it stays correct even when
  toggled from System Settings.
