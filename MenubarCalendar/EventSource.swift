import Foundation
import SwiftUI

/// A calendar the user can include or exclude in Settings.
struct CalendarInfo: Identifiable {
    let id: String
    let title: String
    let color: Color
    /// Whether it counts as selected before the user touches the list
    /// (always for macOS calendars; Google's own selection for Google ones).
    var isSelectedByDefault: Bool = true
}

/// Why a source has nothing to show, if it doesn't.
enum SourceStatus: Equatable {
    case ok
    /// No result yet (first fetch in flight).
    case loading
    /// macOS Calendar access not granted.
    case noAccess
    /// Google source with no accounts connected.
    case notConnected
    /// Google source whose every account must sign in again.
    case needsReconnect
    /// The user unticked every calendar.
    case nothingSelected
    /// Fetches finished but nothing could be loaded — offline or Google errors.
    case unavailable
}

/// Everything `CalendarViewModel` renders, as last read from a source.
struct EventSnapshot {
    /// All calendars, selected or not (for the Settings list).
    var calendars: [CalendarInfo] = []
    /// Events of the selected calendars from the start of today to 7 days out,
    /// with the user's own declines already removed.
    var events: [CalendarEvent] = []
    var accountEmails: [String] = []
    var status: SourceStatus = .loading
}

enum DeclineOutcome {
    /// An RSVP reached Google and the organizer is notified. The source already
    /// hides the event.
    case declined
    /// No RSVP was possible, so only the local copy was removed.
    case removedLocally
    /// Nothing could be done (not invited, read-only calendar, event gone).
    case notApplicable
}

/// Where events come from. `CalendarViewModel` holds exactly one at a time,
/// chosen by `AppSettings.dataSource`.
@MainActor
protocol EventSource: AnyObject {
    /// Called whenever `snapshot` may have changed.
    var onChange: (@MainActor () -> Void)? { get set }
    var snapshot: EventSnapshot { get }
    func start()
    func stop()
    /// Ask for fresh data; `force: false` may be skipped if the data is recent.
    func refresh(force: Bool)
    /// Decline the event whose `CalendarEvent.identifier` is `eventID`.
    func decline(eventID: String) async throws -> DeclineOutcome
}

/// Appends to `/private/tmp/mbc_diag.log` — the app's existing debug trail.
enum Diagnostics {
    static func log(_ message: String) {
        let path = "/private/tmp/mbc_diag.log"
        let line = "\(Date()) [pid \(ProcessInfo.processInfo.processIdentifier)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
