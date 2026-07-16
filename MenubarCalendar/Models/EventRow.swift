import SwiftUI

/// A single row rendered in the pop-over list. Pre-formatted for display so the
/// view stays dumb.
struct EventRow: Identifiable {
    let id: String
    let title: String
    /// e.g. `14:30`, `jutro · 09:00`, `Cały dzień`, `Cały dzień · pt`.
    let subtitle: String
    let calendarColor: Color
    let calendarTitle: String
    let isAllDay: Bool
}
