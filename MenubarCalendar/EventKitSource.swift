import AppKit
import EventKit
import SwiftUI

/// Events from macOS's calendar database via EventKit — whatever accounts are
/// set up in System Settings → Internet Accounts / Calendar.app. EventKit is
/// queried afresh on every `snapshot` read, so the 30-second tick picks up
/// changes even without `.EKEventStoreChanged`.
@MainActor
final class EventKitSource: EventSource {
    var onChange: (@MainActor () -> Void)?

    private let store = EKEventStore()
    private let settings: AppSettings
    /// Used to send a real "declined" RSVP that notifies the organizer.
    private let google: GoogleAccountStore
    /// The `EKEvent` behind each `CalendarEvent.identifier` of the last
    /// snapshot, so decline/edit act on the exact occurrence on screen —
    /// including a single instance of a recurring event.
    private var eventsByID: [String: EKEvent] = [:]
    private var observer: NSObjectProtocol?

    /// iCal UIDs the user has declined through the Google API. A decline keeps
    /// the event on the server (marked declined) rather than deleting it, so
    /// these are hidden locally until sync catches up. Persisted so they don't
    /// reappear after a restart.
    private var declinedUIDs: Set<String> {
        didSet { UserDefaults.standard.set(Array(declinedUIDs), forKey: "declinedICalUIDs") }
    }

    init(settings: AppSettings, google: GoogleAccountStore) {
        self.settings = settings
        self.google = google
        self.declinedUIDs = Set(UserDefaults.standard.stringArray(forKey: "declinedICalUIDs") ?? [])
    }

    func start() {
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.onChange?() }
        }
        requestAccess()
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    func refresh(force: Bool) {
        onChange?()
    }

    private func requestAccess() {
        let status = EKEventStore.authorizationStatus(for: .event)
        Diagnostics.log("authorizationStatus rawValue=\(status.rawValue)")
        guard status == .notDetermined else {
            onChange?()
            return
        }
        store.requestFullAccessToEvents { [weak self] granted, error in
            Diagnostics.log("requestFullAccessToEvents granted=\(granted) error=\(String(describing: error))")
            Task { @MainActor in self?.onChange?() }
        }
    }

    // MARK: - Snapshot

    var snapshot: EventSnapshot {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            break
        case .notDetermined:
            eventsByID = [:]
            return EventSnapshot(status: .loading)
        default: // .denied, .restricted, .writeOnly
            eventsByID = [:]
            return EventSnapshot(status: .noAccess)
        }

        let cal = Calendar.current
        let now = Date()
        let end = cal.date(byAdding: .day, value: 7, to: now) ?? now

        let allCalendars = store.calendars(for: .event)
        let calendars = allCalendars.map {
            CalendarInfo(id: $0.calendarIdentifier, title: $0.title, color: Self.color(for: $0))
        }
        // Seed the account list from the calendars themselves, so an account
        // with no upcoming meeting is still configurable in Settings.
        var accounts = Set<String>()
        for calendar in allCalendars {
            for candidate in [calendar.source.title, calendar.title] where candidate.contains("@") {
                accounts.insert(candidate)
            }
        }

        let selected = allCalendars.filter { settings.isSelected($0.calendarIdentifier, in: .eventKit) }
        // Empty means the user deselected everything → show nothing (don't fall
        // back to querying all calendars, which `calendars: nil` would do).
        guard !selected.isEmpty else {
            eventsByID = [:]
            return EventSnapshot(calendars: calendars, events: [], accountEmails: accounts.sorted(), status: .ok)
        }

        let predicate = store.predicateForEvents(
            withStart: cal.startOfDay(for: now), end: end, calendars: selected
        )
        var byID: [String: EKEvent] = [:]
        let events = store.events(matching: predicate)
            .filter { !isDeclined($0) }
            .map { ek -> CalendarEvent in
                let id = "\(ek.calendarItemIdentifier)@\(ek.startDate.timeIntervalSince1970)"
                byID[id] = ek
                let editable = ek.calendar.allowsContentModifications
                let event = CalendarEvent(
                    identifier: id,
                    title: ek.title ?? "",
                    startDate: ek.startDate,
                    endDate: ek.endDate,
                    isAllDay: ek.isAllDay,
                    calendarIdentifier: ek.calendar.calendarIdentifier,
                    calendarTitle: ek.calendar.title,
                    url: ek.url,
                    location: ek.location,
                    notes: ek.notes,
                    accountEmail: accountEmail(for: ek),
                    iCalUID: ek.calendarItemExternalIdentifier,
                    isEditable: editable,
                    canDecline: editable
                )
                if let email = event.accountEmail { accounts.insert(email) }
                return event
            }
        eventsByID = byID
        return EventSnapshot(calendars: calendars, events: events, accountEmails: accounts.sorted(), status: .ok)
    }

    // MARK: - Decline

    /// With a usable Google account and an iCal UID, send a real "declined"
    /// RSVP through whichever account holds a writable copy, then hide the
    /// event. One account's API error doesn't stop the others being tried; if
    /// none succeeds and any failed, the last error is thrown and nothing is
    /// removed, so the user isn't left hidden-but-still-attending. If every
    /// account answered "not found" (or Google isn't usable), the local copy is
    /// removed instead, which does *not* reliably notify the organizer.
    func decline(eventID: String) async throws -> DeclineOutcome {
        guard let event = eventsByID[eventID] else { return .notApplicable }
        if google.hasUsableAccount, let uid = event.calendarItemExternalIdentifier, !uid.isEmpty {
            var lastError: Error?
            for account in google.accounts where !account.needsReconnect {
                do {
                    if try await google.declineEvent(iCalUID: uid, as: account.email) {
                        declinedUIDs.insert(uid)
                        eventsByID[eventID] = nil
                        return .declined
                    }
                } catch {
                    Diagnostics.log("google decline via \(account.email) failed: \(error)")
                    lastError = error
                }
            }
            // An API failure must not fall through to a local remove: that would
            // hide the event while the user still shows as attending.
            if let lastError { throw lastError }
            Diagnostics.log("google decline: event not found on a writable calendar, falling back")
        }
        do {
            try store.remove(event, span: .thisEvent, commit: true)
            eventsByID[eventID] = nil
            return .removedLocally
        } catch {
            Diagnostics.log("remove failed for \(eventID): \(error)")
            return .notApplicable
        }
    }

    /// Whether the current user has declined this event, or we declined it via
    /// the Google API and are hiding it until sync catches up.
    private func isDeclined(_ event: EKEvent) -> Bool {
        if let uid = event.calendarItemExternalIdentifier, declinedUIDs.contains(uid) {
            return true
        }
        return event.attendees?.contains {
            $0.isCurrentUser && $0.participantStatus == .declined
        } ?? false
    }

    // MARK: - Edit

    /// A snapshot of the editable fields, or `nil` if the event is gone or
    /// lives in a read-only calendar.
    func editDraft(eventID: String) -> EventEditDraft? {
        guard let event = eventsByID[eventID],
              event.calendar.allowsContentModifications else { return nil }
        return EventEditDraft(
            title: event.title ?? "",
            isAllDay: event.isAllDay,
            startDate: event.startDate,
            endDate: event.endDate,
            location: event.location ?? "",
            notes: event.notes ?? "",
            hasAttendees: !(event.attendees ?? []).isEmpty
        )
    }

    /// Write an edited draft back and save it. A synced account propagates the
    /// change and notifies guests on the next sync.
    func saveEdit(_ draft: EventEditDraft, eventID: String) -> Bool {
        guard let event = eventsByID[eventID],
              event.calendar.allowsContentModifications else { return false }
        event.title = draft.title
        event.isAllDay = draft.isAllDay
        event.startDate = draft.startDate
        event.endDate = draft.endDate
        event.location = draft.location.isEmpty ? nil : draft.location
        event.notes = draft.notes.isEmpty ? nil : draft.notes
        do {
            try store.save(event, span: .thisEvent, commit: true)
            return true
        } catch {
            Diagnostics.log("save failed for \(eventID): \(error)")
            return false
        }
    }

    // MARK: - Helpers

    /// Best guess at which account an event belongs to: the "current user"
    /// attendee's address, else the calendar's account / title if it's an email.
    private func accountEmail(for event: EKEvent) -> String? {
        if let attendees = event.attendees {
            for participant in attendees where participant.isCurrentUser {
                if let email = Self.email(fromParticipantURL: participant.url) {
                    return email
                }
            }
        }
        let sourceTitle = event.calendar.source.title
        if sourceTitle.contains("@") { return sourceTitle }
        if event.calendar.title.contains("@") { return event.calendar.title }
        return nil
    }

    static func email(fromParticipantURL url: URL) -> String? {
        guard url.scheme?.lowercased() == "mailto" else { return nil }
        let email = url.absoluteString.dropFirst("mailto:".count)
        return email.isEmpty ? nil : String(email)
    }

    private static func color(for calendar: EKCalendar) -> Color {
        if let cg = calendar.cgColor {
            return Color(cgColor: cg)
        }
        return .gray
    }
}
