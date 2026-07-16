import Foundation

/// Pure, deterministic logic for turning a set of calendar events into the
/// menu-bar label and the pop-over list. No EventKit, no SwiftUI — everything
/// here is a plain function of its inputs so it can be unit-tested.
enum EventLogic {
    /// Max length of the event title shown in the menu bar (PRD §3.1: ~20 chars).
    static let titleMaxLength = 20

    /// Polish abbreviated weekday names, indexed by `Calendar` weekday - 1
    /// (1 = Sunday … 7 = Saturday). Hard-coded to guarantee the exact strings
    /// from the PRD (e.g. Friday → "pt") regardless of the system locale.
    static let polishShortWeekdays = ["niedz", "pon", "wt", "śr", "czw", "pt", "sob"]

    /// English abbreviated weekday names for the menu bar, same indexing.
    static let englishShortWeekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    /// A meeting drops out of the menu bar once it has less than this left, so
    /// the bar moves on to the next event instead of sitting at "0m left".
    static let ongoingMinimumRemaining: TimeInterval = 60

    // MARK: - Titles

    /// Title for the menu bar: trimmed, empty → placeholder, truncated to
    /// `maxLength` characters (the "…" separator is appended by the caller).
    static func truncatedTitle(_ title: String, maxLength: Int = titleMaxLength) -> String {
        let name = listTitle(title)
        return name.count > maxLength ? String(name.prefix(maxLength)) : name
    }

    /// Title for the pop-over list: trimmed, empty → placeholder, not truncated
    /// (SwiftUI truncates visually with `lineLimit`).
    static func listTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(bez tytułu)" : trimmed
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

    /// `dziś` / `jutro` / short weekday (`pt`) — Polish, for the pop-over list.
    static func dayLabel(for date: Date, now: Date, calendar: Calendar) -> String {
        resolvedDayLabel(for: date, now: now, calendar: calendar,
                         today: "dziś", tomorrow: "jutro", weekdays: polishShortWeekdays)
    }

    /// `today` / `tomorrow` / short weekday (`Fri`) — English, for the menu bar.
    static func menuBarDayLabel(for date: Date, now: Date, calendar: Calendar) -> String {
        resolvedDayLabel(for: date, now: now, calendar: calendar,
                         today: "today", tomorrow: "tomorrow", weekdays: englishShortWeekdays)
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

    /// Subtitle for a list row: time for timed events, `Cały dzień` for all-day,
    /// prefixed/suffixed with the day when the event isn't today.
    static func rowSubtitle(for event: CalendarEvent, now: Date, calendar: Calendar) -> String {
        let day = calendar.isDate(event.startDate, inSameDayAs: now)
            ? nil
            : dayLabel(for: event.startDate, now: now, calendar: calendar)
        if event.isAllDay {
            if let day { return "Cały dzień · \(day)" }
            return "Cały dzień"
        }
        let time = timeString(for: event.startDate, calendar: calendar)
        if let day { return "\(day) · \(time)" }
        return time
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

    // MARK: - List (PRD §4.3, §4.5)

    /// Up to `limit` events, sorted ascending by start; on ties a timed event
    /// sorts before an all-day one.
    static func upcomingList(
        _ events: [CalendarEvent], now: Date, showAllDay: Bool, calendar: Calendar, limit: Int = 5
    ) -> [CalendarEvent] {
        let sorted = candidates(events, now: now, showAllDay: showAllDay, calendar: calendar)
            .sorted { a, b in
                if a.startDate != b.startDate { return a.startDate < b.startDate }
                if a.isAllDay != b.isAllDay { return !a.isAllDay }
                return a.identifier < b.identifier
            }
        return Array(sorted.prefix(limit))
    }

    // MARK: - Menu-bar selection (PRD §3.4, §4.4)

    /// The event shown in the menu bar. A meeting *in progress* takes priority
    /// (so the bar shows its remaining time instead of jumping to the next
    /// event); if several overlap, the one ending soonest wins. Otherwise the
    /// choice is by nearest *day*, and within the same day a timed event outranks
    /// an all-day one (PRD §3.4: all-day is the "background" of the day), so an
    /// all-day *today* wins over a timed event *tomorrow*.
    static func menuBarSelection(
        _ events: [CalendarEvent], now: Date, showAllDay: Bool, calendar: Calendar
    ) -> CalendarEvent? {
        let ongoing = inProgressTimedEvents(events, now: now)
            .filter { $0.endDate.timeIntervalSince(now) >= ongoingMinimumRemaining }
        if let current = ongoing.min(by: { $0.endDate < $1.endDate }) {
            return current
        }
        return candidates(events, now: now, showAllDay: showAllDay, calendar: calendar).min { a, b in
            let dayA = calendar.startOfDay(for: a.startDate)
            let dayB = calendar.startOfDay(for: b.startDate)
            if dayA != dayB { return dayA < dayB }
            if a.isAllDay != b.isAllDay { return !a.isAllDay }
            return a.startDate < b.startDate
        }
    }

    /// The full menu-bar label: `Standup… 15m left` while a meeting is running,
    /// `Standup… in 27m` before it starts, or `Urlop… (dziś)` for all-day.
    /// Falls back to `Brak wydarzeń` when there is nothing to show.
    static func menuBarTitle(
        _ events: [CalendarEvent], now: Date, showAllDay: Bool, calendar: Calendar
    ) -> String {
        guard let event = menuBarSelection(events, now: now, showAllDay: showAllDay, calendar: calendar) else {
            return "No events"
        }
        let title = truncatedTitle(event.title)
        if isInProgress(event, now: now) {
            return "\(title)… \(remainingString(from: now, to: event.endDate))"
        }
        if event.isAllDay {
            return "\(title)… (\(menuBarDayLabel(for: event.startDate, now: now, calendar: calendar)))"
        }
        return "\(title)… \(countdownString(from: now, to: event.startDate))"
    }
}
