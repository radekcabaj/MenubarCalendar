import AppKit
import Combine
import EventKit
import SwiftUI

/// Owns the `EKEventStore`, calendar access, the 30-second refresh timer, and
/// publishes the derived state consumed by the UI (PRD §6).
@MainActor
final class CalendarViewModel: ObservableObject {
    /// Text shown in the menu bar, e.g. `Standup… in 27m`.
    @Published var menuBarTitle: String = "…"
    /// The upcoming events shown in the pop-over, grouped into the next 3 days.
    @Published var sections: [DaySection] = []
    /// True when the user has denied (or not granted) calendar access.
    @Published var accessDenied: Bool = false
    /// All event calendars, for the settings picker.
    @Published private(set) var availableCalendars: [CalendarInfo] = []
    /// The event currently shown in the menu bar (target of the meeting hot key).
    @Published private(set) var selectedEvent: CalendarEvent?

    struct CalendarInfo: Identifiable {
        let id: String
        let title: String
        let color: Color
    }

    private let store = EKEventStore()
    /// The live `EKEvent`s currently shown, keyed by `CalendarEvent.identifier`
    /// (== `EventRow.id`), so the swipe actions can act on the exact occurrence
    /// on screen — including a single instance of a recurring event.
    private var eventsByRowID: [String: EKEvent] = [:]
    /// Joinable meeting link (and its account) per row id, for tap/hover "Join".
    private var meetingByRowID: [String: (url: URL, accountEmail: String?)] = [:]
    private let settings: AppSettings
    /// Google Calendar connection, used to send a real "declined" RSVP that
    /// notifies the organizer (EventKit can't). Injected so it can be shared
    /// with the settings UI.
    let google: GoogleCalendarService
    private let hotKey = HotKeyManager()
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    /// iCal UIDs the user has declined through the Google API this install.
    /// A decline keeps the event on the server (marked declined) rather than
    /// deleting it, so we hide these locally until sync catches up. Persisted so
    /// they don't reappear after a restart.
    private var declinedUIDs: Set<String> {
        didSet { UserDefaults.standard.set(Array(declinedUIDs), forKey: "declinedICalUIDs") }
    }

    /// A Polish-locale calendar so day/time labels match the PRD copy.
    private var calendar: Calendar {
        var cal = Calendar.current
        cal.locale = Locale(identifier: "pl_PL")
        return cal
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    init(settings: AppSettings, google: GoogleCalendarService) {
        self.settings = settings
        self.google = google
        self.declinedUIDs = Set(UserDefaults.standard.stringArray(forKey: "declinedICalUIDs") ?? [])

        // Don't touch EventKit / timers when hosted by the unit-test runner.
        guard !Self.isRunningTests else { return }

        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }

        // Reload + re-register the hot key whenever a setting changes
        // (all-day toggle, calendar selection, or the shortcut itself).
        settings.objectWillChange
            .sink { [weak self] in
                Task { @MainActor in
                    self?.reload()
                    self?.updateHotKey()
                }
            }
            .store(in: &cancellables)

        requestAccess()
        startTimer()
        updateHotKey()
    }

    // MARK: - Access

    private func diag(_ msg: String) {
        let path = "/private/tmp/mbc_diag.log"
        let line = "\(Date()) [pid \(ProcessInfo.processInfo.processIdentifier)] \(msg)\n"
        if let data = line.data(using: .utf8) {
            if let fh = FileHandle(forWritingAtPath: path) {
                fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    func requestAccess() {
        let status = EKEventStore.authorizationStatus(for: .event)
        diag("authorizationStatus rawValue=\(status.rawValue)")
        switch status {
        case .fullAccess:
            accessDenied = false
            reload()
        case .notDetermined:
            diag("calling requestFullAccessToEvents…")
            store.requestFullAccessToEvents { [weak self] granted, error in
                self?.diag("requestFullAccessToEvents granted=\(granted) error=\(String(describing: error))")
                Task { @MainActor in
                    guard let self else { return }
                    if granted {
                        self.accessDenied = false
                        self.reload()
                    } else {
                        self.showNoAccess()
                    }
                }
            }
        default: // .denied, .restricted, .writeOnly
            diag("default branch (denied/restricted/writeOnly) → showNoAccess")
            showNoAccess()
        }
    }

    private func showNoAccess() {
        accessDenied = true
        sections = []
        availableCalendars = []
        selectedEvent = nil
        eventsByRowID = [:]
        meetingByRowID = [:]
        menuBarTitle = "No access"
    }

    // MARK: - Refresh

    private func startTimer() {
        timer?.invalidate()
        // PRD §3.1: refresh the countdown at least every 30 seconds.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    /// Re-query EventKit and recompute the label + list.
    func reload() {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            showNoAccess()
            return
        }
        accessDenied = false

        let cal = calendar
        let now = Date()
        guard let end = cal.date(byAdding: .day, value: 7, to: now) else { return }

        let allCalendars = store.calendars(for: .event)
        availableCalendars = allCalendars.map {
            CalendarInfo(id: $0.calendarIdentifier, title: $0.title, color: color(for: $0))
        }

        let selected = allCalendars.filter { settings.isSelected($0.calendarIdentifier) }
        // Empty means the user deselected everything → show nothing (don't fall
        // back to querying all calendars).
        guard !selected.isEmpty else {
            sections = []
            selectedEvent = nil
            eventsByRowID = [:]
            meetingByRowID = [:]
            menuBarTitle = "No events"
            return
        }

        let predicate = store.predicateForEvents(
            withStart: cal.startOfDay(for: now), end: end, calendars: selected
        )
        var byRowID: [String: EKEvent] = [:]
        var meetingMap: [String: (url: URL, accountEmail: String?)] = [:]
        let events = store.events(matching: predicate)
            .filter { !isDeclined($0) }
            .map { ek -> CalendarEvent in
            let id = "\(ek.calendarItemIdentifier)@\(ek.startDate.timeIntervalSince1970)"
            byRowID[id] = ek
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
                accountEmail: accountEmail(for: ek)
            )
            if let url = EventLinkExtractor.meetingURL(for: event) {
                meetingMap[id] = (url, event.accountEmail)
            }
            return event
        }
        eventsByRowID = byRowID
        meetingByRowID = meetingMap

        let colorByCalendar = Dictionary(
            allCalendars.map { ($0.calendarIdentifier, color(for: $0)) },
            uniquingKeysWith: { first, _ in first }
        )

        let selection = EventLogic.menuBarSelection(
            events, now: now, showAllDay: settings.showAllDay, calendar: cal
        )
        let groups = EventLogic.daySections(
            events, now: now, showAllDay: settings.showAllDay, calendar: cal
        )
        sections = groups.map { group in
            DaySection(
                id: group.dateLabel,
                title: group.title,
                dateLabel: group.dateLabel,
                emptyMessage: group.emptyMessage,
                rows: group.events.map { event in
                    EventRow(
                        id: event.identifier,
                        title: EventLogic.listTitle(event.title),
                        startTime: EventLogic.timeString(for: event.startDate, calendar: cal),
                        endTime: EventLogic.timeString(for: event.endDate, calendar: cal),
                        calendarColor: colorByCalendar[event.calendarIdentifier] ?? .gray,
                        isAllDay: event.isAllDay,
                        isEditable: byRowID[event.identifier]?.calendar.allowsContentModifications ?? false,
                        hasMeeting: meetingMap[event.identifier] != nil,
                        isNext: event.identifier == selection?.identifier,
                        isInProgress: EventLogic.isInProgress(event, now: now)
                    )
                }
            )
        }
        selectedEvent = selection
        menuBarTitle = EventLogic.menuBarTitle(
            events, now: now, showAllDay: settings.showAllDay, calendar: cal
        )
    }

    private func color(for calendar: EKCalendar) -> Color {
        if let cg = calendar.cgColor {
            return Color(cgColor: cg)
        }
        return .gray
    }

    // MARK: - Meeting hot key

    /// (Re)register the global hot key from current settings.
    func updateHotKey() {
        guard !Self.isRunningTests else { return }
        if settings.hotKeyEnabled {
            hotKey.register(
                keyCode: settings.hotKeyKeyCode,
                modifierFlags: settings.hotKeyModifierFlags
            ) { [weak self] in
                self?.openCurrentMeeting()
            }
        } else {
            hotKey.unregister()
        }
    }

    /// Temporarily disable the hot key (e.g. while recording a new one).
    func pauseHotKey() {
        hotKey.unregister()
    }

    /// Open the meeting link for the menu-bar event; fall back to Calendar.app.
    func openCurrentMeeting() {
        guard let event = selectedEvent else {
            NSSound.beep()
            return
        }
        if let url = EventLinkExtractor.meetingURL(for: event) {
            openMeetingURL(url, accountEmail: event.accountEmail)
        } else if let calendar = URL(string: "ical://") {
            NSWorkspace.shared.open(calendar)
        }
    }

    /// Open the meeting link for a specific list row (tap / hover "Join").
    func openMeeting(rowID: String) {
        guard let meeting = meetingByRowID[rowID] else { NSSound.beep(); return }
        openMeetingURL(meeting.url, accountEmail: meeting.accountEmail)
    }

    /// Open in the Chrome profile matching the event's account, if enabled and
    /// resolvable; otherwise open in the default browser.
    private func openMeetingURL(_ url: URL, accountEmail: String?) {
        if settings.openInChromeProfile,
           let email = accountEmail,
           let directory = ChromeProfileResolver.profileDirectory(forEmail: email),
           ChromeProfileResolver.open(url, profileDirectory: directory, accountEmail: email) {
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Swipe actions (decline / edit)

    /// Decline attendance. When a Google account is connected and the event has
    /// an iCal UID, this sends a real "declined" RSVP through the Google API
    /// (`sendUpdates=all`) so the organizer is notified — including events on
    /// calendars shared into the account with edit access. The event is then
    /// hidden locally. If Google isn't connected, or the RSVP can't be sent
    /// (read-only calendar, not an attendee), it falls back to removing the
    /// local copy via EventKit — which does *not* reliably notify the organizer.
    func declineEvent(rowID: String) {
        guard let event = eventsByRowID[rowID] else { NSSound.beep(); return }
        let uid = event.calendarItemExternalIdentifier

        if google.isConnected, let uid, !uid.isEmpty {
            Task { @MainActor in
                do {
                    if try await google.declineEvent(iCalUID: uid) {
                        declinedUIDs.insert(uid)
                        eventsByRowID[rowID] = nil
                        reload()
                        return
                    }
                    // Cleanly found no writable copy / we're not an attendee:
                    // a local remove is the best we can do here.
                    diag("google decline: event not found on a writable calendar, falling back")
                    localRemove(event, rowID: rowID)
                } catch {
                    // A real API failure (e.g. a token missing the calendar
                    // scope). Do NOT locally delete — that would hide the event
                    // while leaving the user shown as attending on Google.
                    diag("google decline failed for \(rowID): \(error)")
                    google.reportDeclineFailure(error)
                    NSSound.beep()
                }
            }
        } else {
            localRemove(event, rowID: rowID)
        }
    }

    /// EventKit fallback: remove the local copy of the event.
    private func localRemove(_ event: EKEvent, rowID: String) {
        do {
            try store.remove(event, span: .thisEvent, commit: true)
            eventsByRowID[rowID] = nil
            reload()
        } catch {
            diag("remove failed for \(rowID): \(error)")
            NSSound.beep()
        }
    }

    /// Whether the current user (or a calendar owned/managed by them) has
    /// declined this event, or we declined it via the Google API and are hiding
    /// it until sync catches up.
    private func isDeclined(_ event: EKEvent) -> Bool {
        if let uid = event.calendarItemExternalIdentifier, declinedUIDs.contains(uid) {
            return true
        }
        return event.attendees?.contains {
            $0.isCurrentUser && $0.participantStatus == .declined
        } ?? false
    }

    /// A snapshot of the editable fields for the event backing `rowID`, or `nil`
    /// if it's gone or lives in a read-only calendar.
    func editDraft(rowID: String) -> EventEditDraft? {
        guard let event = eventsByRowID[rowID],
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

    /// Write an edited draft back to the event and save it. As with a delete, a
    /// synced account propagates the change and notifies guests on the next sync.
    @discardableResult
    func saveEdit(_ draft: EventEditDraft, rowID: String) -> Bool {
        guard let event = eventsByRowID[rowID],
              event.calendar.allowsContentModifications else { NSSound.beep(); return false }
        event.title = draft.title
        event.isAllDay = draft.isAllDay
        event.startDate = draft.startDate
        event.endDate = draft.endDate
        event.location = draft.location.isEmpty ? nil : draft.location
        event.notes = draft.notes.isEmpty ? nil : draft.notes
        do {
            try store.save(event, span: .thisEvent, commit: true)
            reload()
            return true
        } catch {
            diag("save failed for \(rowID): \(error)")
            NSSound.beep()
            return false
        }
    }

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
}
