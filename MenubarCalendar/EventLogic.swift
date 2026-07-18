import Foundation

/// Pure, deterministic logic for turning a set of calendar events into the
/// menu-bar label and the pop-over list. No EventKit, no SwiftUI — everything
/// here is a plain function of its inputs so it can be unit-tested.
enum EventLogic {
    /// Max length of the event title shown in the menu bar (PRD §3.1: ~20 chars).
    static let titleMaxLength = 20

    /// English abbreviated weekday names for the menu bar, indexed by `Calendar`
    /// weekday - 1 (1 = Sunday … 7 = Saturday). Hard-coded so the exact strings
    /// (e.g. Friday → "Fri") don't depend on the system locale.
    static let englishShortWeekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    /// English full weekday names for the pop-over day headers, same indexing.
    static let englishWeekdays = [
        "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"
    ]

    /// A meeting drops out of the menu bar once it has less than this left, so
    /// the bar moves on to the next event instead of sitting at "0m left".
    static let ongoingMinimumRemaining: TimeInterval = 60

    // MARK: - Titles

    /// Title for the menu bar: trimmed, empty → placeholder, truncated to
    /// `maxLength` characters. When it overflows, an ellipsis is appended so the
    /// cut is visible (`Bardzo długie spotkani…`); otherwise the title is returned
    /// verbatim.
    static func truncatedTitle(_ title: String, maxLength: Int = titleMaxLength) -> String {
        let name = listTitle(title)
        return name.count > maxLength ? String(name.prefix(maxLength)) + "…" : name
    }

    /// Title for the pop-over list: trimmed, empty → placeholder, not truncated
    /// (SwiftUI truncates visually with `lineLimit`).
    static func listTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(No title)" : trimmed
    }

    // MARK: - Countdown (PRD §3.1)

    /// `< 60 min` → `in 27m`; `>= 60 min` → `in 2h 15m` (or `in 2h` when even).
    static func countdownString(from now: Date, to start: Date) -> String {
        let totalMinutes = max(0, Int(start.timeIntervalSince(now) / 60))
        if totalMinutes < 60 {
            return "in \(totalMinutes)m"
        }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0 ? "in \(hours)h" : "in \(hours)h \(minutes)m"
    }

    /// Time left of an ongoing meeting: `15m left` / `1h 5m left`.
    static func remainingString(from now: Date, to end: Date) -> String {
        let totalMinutes = max(0, Int(end.timeIntervalSince(now) / 60))
        if totalMinutes < 60 {
            return "\(totalMinutes)m left"
        }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0 ? "\(hours)h left" : "\(hours)h \(minutes)m left"
    }

    // MARK: - Day / time labels

    /// `today` / `tomorrow` / short weekday (`Fri`) — English, for the menu bar.
    static func menuBarDayLabel(for date: Date, now: Date, calendar: Calendar) -> String {
        resolvedDayLabel(for: date, now: now, calendar: calendar,
                         today: "today", tomorrow: "tomorrow", weekdays: englishShortWeekdays)
    }

    /// `Today` / `Tomorrow` / full weekday (`Friday`) — for the pop-over day header.
    static func sectionHeaderTitle(for date: Date, now: Date, calendar: Calendar) -> String {
        resolvedDayLabel(for: date, now: now, calendar: calendar,
                         today: "Today", tomorrow: "Tomorrow", weekdays: englishWeekdays)
    }

    /// `Jul 16` — the date shown next to a pop-over day header. Forced to
    /// English (`en_US_POSIX`) so it doesn't follow the app's Polish calendar.
    static func dateLabel(for date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    private static func resolvedDayLabel(
        for date: Date, now: Date, calendar: Calendar,
        today: String, tomorrow: String, weekdays: [String]
    ) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return today }
        let startOfToday = calendar.startOfDay(for: now)
        if let next = calendar.date(byAdding: .day, value: 1, to: startOfToday),
           calendar.isDate(date, inSameDayAs: next) {
            return tomorrow
        }
        let weekday = calendar.component(.weekday, from: date)
        let index = weekday - 1
        guard weekdays.indices.contains(index) else { return "" }
        return weekdays[index]
    }

    /// `14:30` (always 24-hour).
    static func timeString(for date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? Locale(identifier: "pl_PL")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - Filtering (PRD §4.2)

    /// Timed events that haven't started yet.
    static func visibleTimedEvents(_ events: [CalendarEvent], now: Date) -> [CalendarEvent] {
        events.filter { !$0.isAllDay && $0.startDate > now }
    }

    /// A timed event is "in progress" once it has started and not yet ended.
    static func isInProgress(_ event: CalendarEvent, now: Date) -> Bool {
        !event.isAllDay && event.startDate <= now && event.endDate > now
    }

    /// Timed events happening right now.
    static func inProgressTimedEvents(_ events: [CalendarEvent], now: Date) -> [CalendarEvent] {
        events.filter { isInProgress($0, now: now) }
    }

    /// All-day events that end today or later — only when the toggle is on.
    static func visibleAllDayEvents(
        _ events: [CalendarEvent], now: Date, showAllDay: Bool, calendar: Calendar
    ) -> [CalendarEvent] {
        guard showAllDay else { return [] }
        let startOfToday = calendar.startOfDay(for: now)
        return events.filter { $0.isAllDay && $0.endDate >= startOfToday }
    }

    private static func candidates(
        _ events: [CalendarEvent], now: Date, showAllDay: Bool, calendar: Calendar
    ) -> [CalendarEvent] {
        visibleTimedEvents(events, now: now)
            + visibleAllDayEvents(events, now: now, showAllDay: showAllDay, calendar: calendar)
    }

    // MARK: - Day-grouped list (PRD §4.3, §4.5)

    /// One day's worth of events for the pop-over, with its header strings.
    struct DayGroup {
        /// Start of the day this group represents.
        let date: Date
        /// `Today` / `Tomorrow` / weekday name.
        let title: String
        /// `Jul 16`.
        let dateLabel: String
        /// Events on this day, already filtered and sorted for display.
        let events: [CalendarEvent]
        /// When `events` is empty, the message to show in its place:
        /// `No more events left today` (today, all done) or `No events this day`.
        /// `nil` when there are events to show.
        let emptyMessage: String?
    }

    /// The pop-over list grouped into the next three days: today, tomorrow and
    /// the day after. All three days are always returned — even when empty — so
    /// the user never wonders whether a missing day is a bug. Today shows only
    /// events that are in progress or still to come (`endDate > now`); the other
    /// two days show every event. All-day events are gated by `showAllDay` and
    /// matched by overlap so a multi-day event appears under each day it covers.
    /// An empty day carries an `emptyMessage`: `No more events left today` when
    /// today had events that all ended, otherwise `No events this day`.
    static func daySections(
        _ events: [CalendarEvent], now: Date, showAllDay: Bool, calendar: Calendar
    ) -> [DayGroup] {
        let startOfToday = calendar.startOfDay(for: now)
        var groups: [DayGroup] = []

        for offset in 0...2 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfToday),
                  let nextDay = calendar.date(byAdding: .day, value: 1, to: day)
            else { continue }

            // Everything that falls on this day (all-day gated by the toggle),
            // before the "already ended" filter — used to tell an all-done today
            // apart from a genuinely empty day.
            let overlapping = events.filter { event in
                if event.isAllDay && !showAllDay { return false }
                return overlaps(event, dayStart: day, dayEnd: nextDay, calendar: calendar)
            }

            let dayEvents = overlapping
                // Today: hide events that have already ended.
                .filter { offset != 0 || $0.endDate > now }
                .sorted { a, b in
                    if a.startDate != b.startDate { return a.startDate < b.startDate }
                    if a.isAllDay != b.isAllDay { return !a.isAllDay }
                    return a.identifier < b.identifier
                }

            let emptyMessage: String?
            if dayEvents.isEmpty {
                emptyMessage = (offset == 0 && !overlapping.isEmpty)
                    ? "No more events left today"
                    : "No events this day"
            } else {
                emptyMessage = nil
            }

            groups.append(DayGroup(
                date: day,
                title: sectionHeaderTitle(for: day, now: now, calendar: calendar),
                dateLabel: dateLabel(for: day, calendar: calendar),
                events: dayEvents,
                emptyMessage: emptyMessage
            ))
        }

        return groups
    }

    /// Whether an event falls on a given day. Timed events are matched by their
    /// start day; all-day events by range overlap (they can span several days).
    private static func overlaps(
        _ event: CalendarEvent, dayStart: Date, dayEnd: Date, calendar: Calendar
    ) -> Bool {
        if event.isAllDay {
            return event.startDate < dayEnd && event.endDate > dayStart
        }
        return calendar.isDate(event.startDate, inSameDayAs: dayStart)
    }

    // MARK: - Menu-bar selection (PRD §3.4, §4.4)

    /// The event shown in the menu bar — restricted to what is relevant *today*.
    /// A meeting *in progress* takes priority (so the bar shows its remaining time
    /// instead of jumping ahead); if several overlap, the one ending soonest wins.
    /// Otherwise the candidate must be happening today — a timed event later today
    /// or an all-day event covering today — and within today a timed event
    /// outranks an all-day one (PRD §3.4: all-day is the "background" of the day).
    /// Events on later days are deliberately ignored so the bar doesn't surface a
    /// far-out countdown; when nothing is left today it returns `nil`.
    static func menuBarSelection(
        _ events: [CalendarEvent], now: Date, showAllDay: Bool, calendar: Calendar
    ) -> CalendarEvent? {
        let ongoing = inProgressTimedEvents(events, now: now)
            .filter { $0.endDate.timeIntervalSince(now) >= ongoingMinimumRemaining }
        if let current = ongoing.min(by: { $0.endDate < $1.endDate }) {
            return current
        }

        let startOfToday = calendar.startOfDay(for: now)
        guard let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday)
        else { return nil }

        let today = candidates(events, now: now, showAllDay: showAllDay, calendar: calendar).filter { event in
            if event.isAllDay {
                // Covers today (started on/before today and not yet ended).
                return event.startDate < startOfTomorrow && event.endDate > startOfToday
            }
            // Timed event later today (candidates already dropped past ones).
            return calendar.isDate(event.startDate, inSameDayAs: now)
        }
        return today.min { a, b in
            if a.isAllDay != b.isAllDay { return !a.isAllDay }
            return a.startDate < b.startDate
        }
    }

    /// The full menu-bar label: `Standup · 15m left` while a meeting is running,
    /// `Standup · in 27m` before it starts, or `Urlop · (today)` for all-day. The
    /// title carries a trailing `…` only when it was truncated. Falls back to
    /// `No events today` when nothing is left today.
    static func menuBarTitle(
        _ events: [CalendarEvent], now: Date, showAllDay: Bool, calendar: Calendar
    ) -> String {
        guard let event = menuBarSelection(events, now: now, showAllDay: showAllDay, calendar: calendar) else {
            return "No events today"
        }
        let title = truncatedTitle(event.title)
        if isInProgress(event, now: now) {
            return "\(title) · \(remainingString(from: now, to: event.endDate))"
        }
        if event.isAllDay {
            // Selection guarantees the all-day event covers today, so a multi-day
            // one that started earlier should still read "(today)".
            let day = max(event.startDate, calendar.startOfDay(for: now))
            return "\(title) · (\(menuBarDayLabel(for: day, now: now, calendar: calendar)))"
        }
        return "\(title) · \(countdownString(from: now, to: event.startDate))"
    }
}
