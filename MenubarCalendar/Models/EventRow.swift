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
    /// Whether the backing event lives in a writable calendar, i.e. whether the
    /// Decline / Edit swipe actions should be offered for this row.
    let isEditable: Bool
    /// Whether the event has a joinable meeting link (shows the Join affordance).
    var hasMeeting: Bool = false
    /// Whether this is the event surfaced in the menu bar (next up / current) —
    /// it gets an accent highlight so the eye lands on it first.
    var isNext: Bool = false
    /// Whether the event is happening right now (drives the live pulse).
    var isInProgress: Bool = false
}

/// A mutable snapshot of an event's editable fields. Produced by
/// `CalendarViewModel.editDraft(rowID:)`, edited in `EventEditScreen`, and
/// written back through `CalendarViewModel.saveEdit(_:rowID:)`.
struct EventEditDraft {
    var title: String
    var isAllDay: Bool
    var startDate: Date
    var endDate: Date
    var location: String
    var notes: String
    /// Whether the event has guests — drives the "guests will be notified" note
    /// so the user knows an edit is not silent.
    var hasAttendees: Bool
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
