# Design — Google Calendar API as an event source

Date: 2026-10-02

## Problem

Every event the app shows comes from EventKit (`EKEventStore` in
`CalendarViewModel`). EventKit only sees Google accounts added to macOS
(System Settings → Internet Accounts), and macOS decides when they sync. Without
Apple Calendar set up, the app shows nothing; with it, freshness depends on
macOS's sync. The user wants the app to fetch Google Calendar itself, in the
background, so the Apple Calendar dependency can be dropped.

## Decisions (agreed)

- **Per-install source choice.** Settings gets a "Data source" switch:
  *Google API* or *macOS Calendar*. Never both at once, never merged.
- **Multiple Google accounts**, each signed in separately, so every event knows
  its true owning account (needed for Chrome-profile routing / `authuser=`).
- **Day-one scope in Google mode:** list, countdown, meeting links, Chrome
  routing, hot key, decline. **Edit is unavailable** in Google mode (rows report
  `isEditable = false`); a later change can port it to `events.patch`.
- **Sync = polling a fixed window**, no backend, no push, no sync tokens.

## Sync mechanism

`GoogleAPISource` polls each connected account:

1. `GET users/me/calendarList` → calendars (id, summary, `backgroundColor`,
   `accessRole`, `primary`).
2. For each **selected** calendar: `GET calendars/{id}/events` with
   `timeMin = startOfDay(now)`, `timeMax = now + 7 days`, `singleEvents=true`,
   `orderBy=startTime`, `showDeleted=false`, `maxResults=250`, following
   `nextPageToken`.

Triggers: every **120 s**; on `NSWorkspace.didWakeNotification`; when the network
path becomes satisfied (`NWPathMonitor`); when the pop-over opens (debounced: no
re-fetch if the last successful fetch is < 15 s old); immediately after an
account is added/removed, the source switch flips, or the calendar selection
changes. Only one fetch runs at a time — a trigger during a fetch is coalesced
into one follow-up fetch.

The existing 30 s timer stays; in Google mode it only recomputes the label/list
from cached events (countdown), it does not hit the network.

Quota: ~(1 + selected calendars) requests per account per poll — far below
Google's free per-user limits.

## Architecture

### `EventSource` protocol (new, `EventSource.swift`)

```swift
@MainActor protocol EventSource: AnyObject {
    /// Fires whenever calendars/events may have changed.
    var onChange: (() -> Void)? { get set }
    func start()                       // begin observing / polling
    func stop()
    func refreshNow()                  // explicit trigger (pop-over open etc.)
    var snapshot: EventSnapshot { get } // last known good data
    func decline(eventID: String) async throws -> DeclineOutcome
}

struct EventSnapshot {
    var calendars: [CalendarInfo]      // all calendars, selected or not
    var events: [CalendarEvent]        // selected calendars, 7-day window, declined filtered out
    var accountEmails: [String]
    var status: SourceStatus           // .ok, .noAccess, .notConnected, .partial([email])
}
```

`DeclineOutcome`: `.declined` (RSVP sent), `.notApplicable` (not an attendee /
no writable copy), plus thrown errors for real failures.

### `EventKitSource` (new file, code moved from `CalendarViewModel`)

Today's EventKit logic, unchanged in behaviour: access request,
`.EKEventStoreChanged` observer, predicate query, `isDeclined`, `accountEmail`,
local remove fallback, edit draft / save. Decline keeps today's flow: try the
Google accounts (now *each* connected account in turn), fall back to local remove
on `.notApplicable`. Edit stays available here only.

### `GoogleAPISource` (new file)

Owns the poll loop and triggers above, calls `GoogleAccountStore` for tokens,
maps JSON via `GoogleEventMapper`, keeps the last good snapshot per account.

### `GoogleEventMapper` (new, pure, unit-tested)

Maps one Google event JSON + its account email + calendar id to `CalendarEvent?`:

- `status == "cancelled"` → `nil`.
- Self attendee (`self == true`) with `responseStatus == "declined"` → `nil`.
- All-day: `start.date` / `end.date` (end exclusive, as in Google) parsed in the
  local time zone; `isAllDay = true`. Timed: `start.dateTime` (RFC 3339 with
  offset) parsed as absolute dates.
- `url`: `hangoutLink`, else the `conferenceData.entryPoints` entry with
  `entryPointType == "video"`, else `nil`. `location` and `description` → `notes`
  (so `EventLinkExtractor` still finds Zoom/Teams links in text).
- `accountEmail`: the account the event was fetched through.
- `identifier`: `"\(accountEmail)/\(calendarId)/\(eventId)"` (event ids from
  `singleEvents=true` are already per-instance).
- New `CalendarEvent` fields (defaulted, so EventKit mapping and existing tests
  don't change): `iCalUID: String?`, `isEditable: Bool = false`.

**Duplicates across accounts.** The same meeting can show up through two accounts
(e.g. invited on both, or a calendar shared into both). Dedupe by
`(iCalUID, startDate)`; keep the copy whose self attendee exists, else the first
account in connection order.

### `GoogleAccountStore` (replaces the single-account parts of `GoogleCalendarService`)

- `accounts: [GoogleAccount]` (`email`, tokens, `needsReconnect: Bool`), each stored
  as its own Keychain item: service `com.rc.MenubarCalendar.google`, account =
  email. Connection order persisted in `UserDefaults`.
- `addAccount()` runs the existing PKCE / `ASWebAuthenticationSession` flow;
  `remove(email:)`; `validAccessToken(for:)` with per-account refresh.
- Scopes: the existing ones plus `calendar.readonly`
  (`calendar.events` + `calendar.calendarlist.readonly` + `calendar.readonly`).
- **Migration:** on first launch, the legacy item (account `"tokens"`) is
  re-saved under its email and deleted. Its token lacks `calendar.readonly`, so
  the first 403 on a read marks it `needsReconnect` (shown in Settings) instead
  of silently disconnecting.
- A refresh failure / 401 / 403 marks only that account `needsReconnect`; other
  accounts keep syncing (`SourceStatus.partial`).
- Decline (`declineEvent(iCalUID:)`) moves here and takes an account email; the
  REST/PKCE/Keychain helpers move with it. `GoogleCalendarService.swift` is
  renamed to `GoogleAccountStore.swift`.

### `CalendarViewModel`

No longer imports EventKit. Holds the active `EventSource`, swaps it when
`settings.dataSource` changes (stop old, start new), and on `onChange` / the 30 s
tick maps `snapshot` through `EventLogic` into `sections`, `menuBarTitle`,
`selectedEvent`, `meetingByRowID`, `availableCalendars`, `accountEmails` exactly as
`reload()` does today. `declineEvent(rowID:)` delegates to the source; in Google
mode, on `.declined` the event is hidden immediately (the existing
`declinedUIDs` set) until the next poll confirms it. `editDraft` / `saveEdit`
forward to the source only when it is an `EventKitSource` (`as?` cast; edit is
not part of the protocol), else return `nil` / `false`.

### Settings (`AppSettings`, `SettingsView`)

- `dataSource: DataSource` (`.google`, `.eventKit`), key `dataSource`. **Default
  for existing installs: `.eventKit`** (nothing changes until the user switches);
  for fresh installs (no `selectedCalendarIDs` stored): `.google`.
- Calendar selection is stored **per source**: `selectedCalendarIDs` (existing,
  EventKit) and `selectedGoogleCalendarIDs` (Google, ids
  `"\(email)/\(calendarId)"`). `nil` still means "all selected".
- `SettingsView` (UI copy in Polish, matching the rest of the window):
  - "Źródło danych" picker: "Google (bezpośrednio)" / "Kalendarz macOS".
  - The Google section becomes an account list: email, "Połącz ponownie" when
    `needsReconnect`, "Usuń"; plus "Dodaj konto Google…". Shown in both modes,
    since EventKit mode uses it for declines.
  - In Google mode, no EventKit permission is requested.

## Error handling and offline

- Network failure or timeout: keep the last good snapshot. The countdown keeps
  ticking. Show nothing in the menu bar; Settings shows "Ostatnia synchronizacja:
  <time>" per account.
- No accounts connected in Google mode: menu-bar title `"Connect Google"`, the
  pop-over shows a button that opens Settings.
- All accounts `needsReconnect`: same as no accounts, but the copy says
  reconnect.
- HTTP 429 / 5xx: skip this poll and back off (next poll after 2× the interval,
  capped at 10 min, reset on success).
- Decline failure in Google mode: beep and surface `errorMessage`. No local
  fallback, since there is no local copy.

## Testing

- `GoogleEventMapperTests`: timed event with offset; all-day single and
  multi-day (exclusive end); cancelled → nil; self declined → nil; `hangoutLink`
  vs `conferenceData` vs text-only Zoom link; missing title; dedupe rule.
- `GoogleAccountStore` migration: a legacy blob becomes a per-email item,
  ordered first (Keychain behind a small protocol so tests use an in-memory
  fake).
- `AppSettings`: default `dataSource` for existing vs fresh installs; separate
  selection sets.
- Existing `EventLogicTests` etc. unchanged and must pass.
- Manual: with Internet Accounts' Google accounts disabled and Calendar.app
  closed, Google mode shows events from two accounts. A change made on
  calendar.google.com appears within about 2 minutes. Opening a meeting routes to
  the correct Chrome profile. Declining notifies the organizer.

## Out of scope

Editing events in Google mode; push notifications / any backend; non-Google
providers in API mode; merging both sources.
