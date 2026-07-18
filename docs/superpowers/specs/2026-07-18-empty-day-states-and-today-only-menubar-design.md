# Design — Per-day empty states + today-only menu bar

Date: 2026-07-18

## Problem

1. The pop-over omits days that have no events. When tomorrow is empty it simply
   doesn't appear, so the list can look broken ("is this a bug?").
2. The menu-bar label always shows the *nearest upcoming* event, even when it is
   far out (e.g. `Alaffia – daily · in 43h 12m` on a Saturday). That is noise the
   user doesn't want this early — they only care about *today*.

## Change 1 — Pop-over always shows today, tomorrow and the day after

`EventLogic.daySections` always returns exactly **3** groups (today, tomorrow,
day-after). It never omits an empty day. Each `DayGroup` gains
`emptyMessage: String?`:

| Situation                                   | `events`  | `emptyMessage`                |
|---------------------------------------------|-----------|-------------------------------|
| Day has events to show                      | populated | `nil`                         |
| **Today**, had events but all already ended | `[]`      | `"No more events left today"` |
| Any day with zero events at all             | `[]`      | `"No events this day"`        |

- "All ended" (today only) is detected by comparing today's *filtered* list
  (which hides events with `endDate <= now`) against whether *any* event overlaps
  today at all. Filtered-empty **and** had-overlap → all ended.
- Tomorrow / day-after never apply a time filter, so their only empty case is
  zero events → `"No events this day"`.
- All-day toggle off: all-day events are filtered out *before* the overlap check,
  so a day whose only event is a hidden all-day one correctly reads
  `"No events this day"`.

### UI / model

- `DaySection` (Models/EventRow.swift) gains `emptyMessage: String?`.
- `DaySectionView` (EventListView.swift): when `rows` is empty, render
  `emptyMessage` as a single muted, left-aligned line in place of the event rows,
  keeping the day header and spacing intact.
- `CalendarViewModel.reload()` maps `emptyMessage` from `DayGroup` to
  `DaySection`. With 3 always-present groups, `sections` is only empty for the
  access-denied and no-calendars-selected paths (both already handled).

## Change 2 — Menu bar: "No events today" when today is empty

`EventLogic.menuBarSelection` narrows to **today-relevant** events:

1. An in-progress timed meeting (≥ 60s remaining) still wins — unchanged.
2. Otherwise consider only: timed events starting **later today**, or an all-day
   event **covering today** (when the toggle is on).
3. Nothing today → return `nil`.

`EventLogic.menuBarTitle` returns **`"No events today"`** when the selection is
`nil`. In-progress / all-day-today / countdown formatting is otherwise unchanged.

### Hot key (decided: Option A)

The global meeting hot key opens `selectedEvent`, which is `menuBarSelection`.
Because selection is now today-only, the hot key **beeps when the bar shows
"No events today"** — one source of truth: "open what's in the bar." No separate
next-upcoming target.

## Test impact

Pure logic in `EventLogic`, so covered by `EventLogicTests`:

- `testDaySectionsOmitsEmptyDays` — reverses: now expects all 3 groups, with the
  empty ones carrying the right `emptyMessage`.
- `testDaySectionsHidesAllDayWhenToggleOff` — the toggle-off case now returns 3
  empty groups (all `"No events this day"`) instead of `[]`.
- New tests: today-all-ended → `"No more events left today"`; weekend/zero-event
  day → `"No events this day"`; menu bar `"No events today"` when the only events
  are tomorrow-or-later; menu bar still shows an in-progress / all-day-today /
  later-today event.

## Out of scope

No changes to countdown formatting, Chrome-profile opening, settings, or the
7-day query window.
