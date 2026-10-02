import Foundation

/// A calendar-agnostic value type used by the selection and formatting logic.
///
/// Decoupled from EventKit on purpose: keeping `EventLogic` operating on this
/// plain value type makes the countdown / all-day / selection rules pure and
/// unit-testable without needing a live `EKEventStore`.
struct CalendarEvent: Equatable {
    let identifier: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    /// Stable identifier of the owning calendar (used only for UI colouring).
    let calendarIdentifier: String
    let calendarTitle: String
    /// Fields used to find a "join meeting" link (see `EventLinkExtractor`).
    var url: URL? = nil
    var location: String? = nil
    var notes: String? = nil
    /// Email of the account this event belongs to, used to pin Google links to
    /// that account (`authuser=`) when opening them.
    var accountEmail: String? = nil
    /// The iCalendar UID, shared by every copy of an invitation — used to spot
    /// the same meeting seen through two accounts and to hide declines.
    var iCalUID: String? = nil
    /// Whether the edit screen may write this event (macOS Calendar source only).
    var isEditable: Bool = false
    /// Whether Decline applies: a writable calendar the user is invited on.
    var canDecline: Bool = false
}
