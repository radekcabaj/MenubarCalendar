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

### Opening in the right Chrome profile and Google account

Meeting links always open in **Google Chrome**, in the profile that owns the
event's account — so a work meeting lands in the work profile instead of
whichever profile Chrome happened to use last:

1. The event's account is taken from the "current user" attendee's address, or
   the calendar's account / title when it's an email (e.g. `radek@tonik.com`).
2. That email is matched to a Chrome profile — a profile pinned for the account
   in Settings wins; otherwise the email is matched as a profile's **primary**
   account, then as a **secondary** signed-in account (scanned from each
   `<Profile>/Preferences`). The link is opened with `--profile-directory=<dir>`.
3. For Google links (`*.google.com`, so Meet and Calendar included)
   `authuser=<email>` is added to the URL (replacing any existing value), which
   picks the right identity *inside* a multi-account profile.

Steps 2 and 3 are independent and both are needed: `authuser` can only choose
between accounts already signed into the profile Chrome opens — it can never
switch profiles.

Settings → **Profil Chrome dla konta** lists every account and the profile it
resolves to, so a wrong automatic match can be pinned by hand. A pin that points
at a deleted profile falls back to automatic matching.

When Chrome is already running, that command line is handed to it over its
**process-singleton socket** (`SingletonSocket` in the user-data directory)
instead of by starting a second Chrome process. Both routes end up in the same
browser — starting a process only forwards its arguments and exits — but macOS
counts the short-lived process as an app launch and the Dock then keeps a second
"Google Chrome" tile in its recent-apps list next to the pinned one. Starting
Chrome is kept for the cold-start case, where that process *becomes* the
browser. See `ChromeSingleton`.

If Chrome isn't installed or can't be launched, the link falls back to the
system default browser. Everything is read from the user's own local Chrome
data; the parsing and matching logic is a set of pure functions in
`ChromeProfileResolver`, and the `authuser` rewrite lives in
`EventLinkExtractor` — both unit-tested.

On first launch the app requests **full calendar access**. If you deny it, the
pop-over shows a message with a shortcut to System Settings → Privacy →
Calendars.

## Project layout

```
MenubarCalendar/
  MenubarCalendarApp.swift   @main + MenuBarExtra (.window style)
  CalendarViewModel.swift    EventKit store, 30s timer, published UI state, hot key
  EventListView.swift        Pop-over: event list, footer, animated expand
  SettingsView.swift         All-day, launch-at-login, shortcut, Chrome profiles, calendars
  ShortcutRecorder.swift     Click-to-record control for the meeting hot key
  AppSettings.swift          UserDefaults: calendars, all-day, hot key, Chrome profile pins
  LoginItemManager.swift     SMAppService launch-at-login wrapper
  HotKeyManager.swift        Carbon global hot key (RegisterEventHotKey)
  EventLogic.swift           Pure selection/formatting logic (unit-tested)
  EventLinkExtractor.swift   Pure meeting-link extraction + `authuser` rewrite (unit-tested)
  ChromeProfileResolver.swift  Account -> Chrome profile matching + opening (unit-tested)
  ChromeSingleton.swift      Hands a command line to the running Chrome (unit-tested)
  Models/
    CalendarEvent.swift      Value type decoupled from EventKit
    EventRow.swift           Pre-formatted list row
Config/
  Info.plist                 LSUIElement, NSCalendarsFullAccessUsageDescription
MenubarCalendarTests/
  EventLogicTests.swift            30 tests: countdown / all-day / selection
  EventLinkExtractorTests.swift    10 tests: meeting-link extraction, authuser rewrite
  ChromeProfileResolverTests.swift 16 tests: profile parsing, matching, pins, command line
  ChromeSingletonTests.swift        7 tests: wire format, socket lookup, ACK / refusal
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
