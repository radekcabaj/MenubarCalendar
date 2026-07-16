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
    /// The up-to-5 upcoming events shown in the pop-over.
    @Published var upcomingEvents: [EventRow] = []
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
    private let settings: AppSettings
    private let hotKey = HotKeyManager()
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    /// A Polish-locale calendar so day/time labels match the PRD copy.
    private var calendar: Calendar {
        var cal = Calendar.current
        cal.locale = Locale(identifier: "pl_PL")
        return cal
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    init(settings: AppSettings) {
        self.settings = settings

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
        upcomingEvents = []
        availableCalendars = []
        selectedEvent = nil
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
            upcomingEvents = []
            selectedEvent = nil
            menuBarTitle = "No events"
            return
        }

        let predicate = store.predicateForEvents(
            withStart: cal.startOfDay(for: now), end: end, calendars: selected
        )
        let events = store.events(matching: predicate).map { ek in
            CalendarEvent(
                identifier: "\(ek.calendarItemIdentifier)@\(ek.startDate.timeIntervalSince1970)",
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
        }

        let colorByCalendar = Dictionary(
            allCalendars.map { ($0.calendarIdentifier, color(for: $0)) },
            uniquingKeysWith: { first, _ in first }
        )

        let list = EventLogic.upcomingList(
            events, now: now, showAllDay: settings.showAllDay, calendar: cal
        )
        upcomingEvents = list.map { event in
            EventRow(
                id: event.identifier,
                title: EventLogic.listTitle(event.title),
                subtitle: EventLogic.rowSubtitle(for: event, now: now, calendar: cal),
                calendarColor: colorByCalendar[event.calendarIdentifier] ?? .gray,
                calendarTitle: event.calendarTitle,
                isAllDay: event.isAllDay
            )
        }
        selectedEvent = EventLogic.menuBarSelection(
            events, now: now, showAllDay: settings.showAllDay, calendar: cal
        )
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
