import SwiftUI

/// A single event rendered in the pop-over list. Pre-formatted for display so
/// the view stays dumb.
struct EventRow: Identifiable {
    let id: String
    let title: String
    /// Start time, 24-hour, e.g. `11:00`. Empty for all-day events.
    let startTime: String
    /// End time, 24-hour, e.g. `11:15`. Empty for all-day events.
    let endTime: String
    let calendarColor: Color
    let isAllDay: Bool
}

/// A day group in the pop-over: a header (`Today` / `Tomorrow` / `Friday` plus a
/// `Jul 16` date) and the events that fall on that day.
struct DaySection: Identifiable {
    let id: String
    /// `Today` / `Tomorrow` / weekday name.
    let title: String
    /// `Jul 16`.
    let dateLabel: String
    /// Message shown when `rows` is empty (`No more events left today` /
    /// `No events this day`); `nil` when the day has events.
    let emptyMessage: String?
    let rows: [EventRow]
}
