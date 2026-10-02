import AppKit
import Combine
import SwiftUI

/// Turns the active `EventSource`'s snapshot into the menu-bar label and the
/// pop-over list, runs the 30-second countdown timer, and routes the swipe
/// actions and meeting hot key (PRD §6). Knows nothing about EventKit or the
/// Google API — see `EventKitSource` / `GoogleAPISource`.
@MainActor
final class CalendarViewModel: ObservableObject {
    /// Text shown in the menu bar, e.g. `Standup… in 27m`.
    @Published var menuBarTitle: String = "…"
    /// The upcoming events shown in the pop-over, grouped into the next 3 days.
    @Published var sections: [DaySection] = []
    /// True when the user has denied (or not granted) calendar access.
    @Published var accessDenied: Bool = false
    /// Why the active source has nothing to show, if it doesn't.
    @Published private(set) var sourceStatus: SourceStatus = .loading
    /// All calendars of the active source, for the settings picker.
    @Published private(set) var availableCalendars: [CalendarInfo] = []
    /// Account emails seen across the visible events and calendars, so Settings
    /// can offer a Chrome profile per account.
    @Published private(set) var accountEmails: [String] = []
    /// The event currently shown in the menu bar (target of the meeting hot key).
    @Published private(set) var selectedEvent: CalendarEvent?

    private let settings: AppSettings
    /// Google accounts: shared with Settings, used by both sources to decline.
    let google: GoogleAccountStore
    private var source: EventSource
    /// Joinable meeting link (and its account) per row id, for tap/hover "Join".
    private var meetingByRowID: [String: (url: URL, accountEmail: String?)] = [:]
    private let hotKey = HotKeyManager()
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    /// A Polish-locale calendar so day/time labels match the PRD copy.
    private var calendar: Calendar {
        var cal = Calendar.current
        cal.locale = Locale(identifier: "pl_PL")
        return cal
    }

    /// True when hosted by the XCTest runner — skip sources and timers.
    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    init(settings: AppSettings, google: GoogleAccountStore) {
        self.settings = settings
        self.google = google
        self.source = EventKitSource(settings: settings, google: google)

        // Don't touch EventKit / timers when hosted by the unit-test runner.
        guard !Self.isRunningTests else { return }

        source.onChange = { [weak self] in self?.reload() }

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

        source.start()
        startTimer()
        updateHotKey()
    }

    // MARK: - Refresh

    private func startTimer() {
        timer?.invalidate()
        // PRD §3.1: refresh the countdown at least every 30 seconds.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    /// Recompute the label + list from the active source's snapshot.
    func reload() {
        let snapshot = source.snapshot
        sourceStatus = snapshot.status
        accessDenied = snapshot.status == .noAccess
        availableCalendars = snapshot.calendars
        accountEmails = snapshot.accountEmails
        guard snapshot.status == .ok else {
            showEmpty(for: snapshot.status)
            return
        }

        let cal = calendar
        let now = Date()
        let events = snapshot.events
        var meetingMap: [String: (url: URL, accountEmail: String?)] = [:]
        for event in events {
            if let url = EventLinkExtractor.meetingURL(for: event) {
                meetingMap[event.identifier] = (url, event.accountEmail)
            }
        }
        meetingByRowID = meetingMap

        let colorByCalendar = Dictionary(
            snapshot.calendars.map { ($0.id, $0.color) },
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
                        isEditable: event.isEditable,
                        canDecline: event.canDecline,
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

    private func showEmpty(for status: SourceStatus) {
        sections = []
        selectedEvent = nil
        meetingByRowID = [:]
        switch status {
        case .noAccess: menuBarTitle = "No access"
        case .notConnected: menuBarTitle = "Connect Google"
        case .needsReconnect: menuBarTitle = "Reconnect Google"
        case .nothingSelected: menuBarTitle = "No events"
        case .loading, .ok: menuBarTitle = "…"
        }
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

    /// Open in Chrome, pinned to the profile that owns the event's account, so a
    /// work meeting lands in the work profile rather than whichever profile
    /// Chrome happened to use last. Google links additionally get
    /// `authuser=<email>` to pick the right identity *inside* that profile.
    /// Falls back to the default browser only when Chrome can't be launched.
    private func openMeetingURL(_ url: URL, accountEmail: String?) {
        let finalURL = accountEmail.map { EventLinkExtractor.accountURL(url, authuserEmail: $0) } ?? url
        let directory = accountEmail.flatMap {
            ChromeProfileResolver.profileDirectory(
                forEmail: $0, overrides: settings.chromeProfileOverrides
            )
        }
        if ChromeProfileResolver.open(finalURL, profileDirectory: directory) { return }
        NSWorkspace.shared.open(finalURL)
    }

    // MARK: - Swipe actions (decline / edit)

    /// Decline attendance through the active source (a real RSVP where
    /// possible). On an API failure nothing is hidden and the error is shown.
    func declineEvent(rowID: String) {
        Task { @MainActor in
            do {
                switch try await source.decline(eventID: rowID) {
                case .declined, .removedLocally:
                    reload()
                case .notApplicable:
                    NSSound.beep()
                }
            } catch {
                Diagnostics.log("decline failed for \(rowID): \(error)")
                google.reportDeclineFailure(error)
                NSSound.beep()
            }
        }
    }

    /// Editable fields for the row's event; only the macOS Calendar source
    /// supports editing.
    func editDraft(rowID: String) -> EventEditDraft? {
        (source as? EventKitSource)?.editDraft(eventID: rowID)
    }

    @discardableResult
    func saveEdit(_ draft: EventEditDraft, rowID: String) -> Bool {
        guard let eventKit = source as? EventKitSource,
              eventKit.saveEdit(draft, eventID: rowID) else {
            NSSound.beep()
            return false
        }
        reload()
        return true
    }
}
