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
    /// Email of the account this event belongs to, for Chrome-profile matching.
    var accountEmail: String? = nil
}
