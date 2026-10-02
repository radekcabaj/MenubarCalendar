import AppKit
import Combine
import Foundation
import Network
import SwiftUI

/// When to poll: every 2 minutes, doubling after a throttled poll up to 10
/// minutes, back to 2 after a good one. Pure, so it is unit-tested.
struct PollSchedule {
    static let baseInterval: TimeInterval = 120
    static let maxInterval: TimeInterval = 600
    /// Opening the pop-over within this long of a good fetch doesn't refetch.
    static let freshness: TimeInterval = 15

    private(set) var interval: TimeInterval = baseInterval

    mutating func recordSuccess() { interval = Self.baseInterval }
    mutating func recordThrottled() { interval = min(interval * 2, Self.maxInterval) }

    static func isFresh(lastSuccess: Date?, now: Date) -> Bool {
        guard let lastSuccess else { return false }
        return now.timeIntervalSince(lastSuccess) < freshness
    }
}

/// Events fetched straight from the Google Calendar API for every connected
/// account — no Calendar.app, no macOS Internet Accounts, no backend.
///
/// Polls a fixed window (start of today → now + 7 days) every
/// `PollSchedule.interval`, and also on wake, when the network comes back,
/// when the pop-over opens (unless fresh), and when accounts or the calendar
/// selection change. Only one fetch runs at a time; a trigger during a fetch
/// queues exactly one follow-up. The last good result per account is kept
/// across network failures so the countdown keeps working offline.
@MainActor
final class GoogleAPISource: EventSource {
    var onChange: (@MainActor () -> Void)?
    private(set) var snapshot = EventSnapshot()

    private struct AccountResult {
        var calendars: [GoogleCalendarEntry]
        var events: [MappedGoogleEvent]
    }

    private let accounts: GoogleAccountStore
    private let settings: AppSettings
    private var results: [String: AccountResult] = [:]
    private var eventsByID: [String: MappedGoogleEvent] = [:]
    private var schedule = PollSchedule()
    private var lastSuccess: Date?
    private var isRunning = false
    private var isFetching = false
    private var refetchQueued = false
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    private var networkWasDown = false
    private var cancellables = Set<AnyCancellable>()

    init(accounts: GoogleAccountStore, settings: AppSettings) {
        self.accounts = accounts
        self.settings = settings
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true

        // Accounts added/removed or reconnected → fetch now.
        accounts.$accounts
            .map { $0.map { "\($0.email)|\($0.needsReconnect)" } }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.refresh(force: true) } }
            .store(in: &cancellables)

        // A newly ticked calendar has nothing cached yet → fetch now.
        settings.$selectedGoogleCalendarIDs
            .dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.refresh(force: true) } }
            .store(in: &cancellables)

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh(force: true) }
        }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let isUp = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(isUp: isUp) }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor

        rebuildSnapshot()
        onChange?()
        refresh(force: true)
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        cancellables.removeAll()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    func refresh(force: Bool) {
        guard isRunning else { return }
        if !force && PollSchedule.isFresh(lastSuccess: lastSuccess, now: Date()) { return }
        guard !isFetching else {
            refetchQueued = true
            return
        }
        Task { await fetchAll() }
    }

    private func networkChanged(isUp: Bool) {
        if isUp && networkWasDown { refresh(force: true) }
        networkWasDown = !isUp
    }

    // MARK: - Fetching

    private func fetchAll() async {
        isFetching = true
        let window = Self.window(now: Date())
        let emails = accounts.accounts.filter { !$0.needsReconnect }.map(\.email)
        // Forget accounts that were removed or must reconnect.
        results = results.filter { emails.contains($0.key) }

        var throttled = false
        var anySuccess = false
        for email in emails {
            do {
                results[email] = try await fetchAccount(email, window: window)
                accounts.recordSync(email: email)
                anySuccess = true
            } catch {
                Diagnostics.log("google fetch failed for \(email): \(error)")
                if GoogleAccountStore.isRateLimited(error) || Self.isServerError(error) {
                    throttled = true
                }
                // The store already marked an auth failure for reconnect; drop
                // that account's events. Other failures keep the last good result.
                if GoogleAccountStore.isAuthFailure(error) {
                    results[email] = nil
                }
            }
        }
        if throttled {
            schedule.recordThrottled()
        } else if anySuccess {
            schedule.recordSuccess()
        }
        if anySuccess { lastSuccess = Date() }
        isFetching = false

        rebuildSnapshot()
        onChange?()
        scheduleNextPoll()
        if refetchQueued {
            refetchQueued = false
            refresh(force: true)
        }
    }

    private func fetchAccount(_ email: String, window: (start: Date, end: Date)) async throws -> AccountResult {
        let calendars = try await pagedItems(Self.calendarListURL, as: email)
            .compactMap { GoogleEventMapper.calendar(from: $0, accountEmail: email) }
        var events: [MappedGoogleEvent] = []
        for calendar in calendars where isSelected(calendar) {
            do {
                let items = try await pagedItems(Self.eventsURL(calendarID: calendar.calendarID, window: window), as: email)
                events += items.compactMap { GoogleEventMapper.event(from: $0, calendar: calendar) }
            } catch let error where Self.isPerCalendarError(error) {
                // e.g. 404 for a calendar unsubscribed since the list call: skip it.
                Diagnostics.log("google fetch skipped \(calendar.key): \(error)")
            }
        }
        return AccountResult(calendars: calendars, events: events)
    }

    /// Every `items` entry across `nextPageToken` pages.
    private func pagedItems(_ url: URL, as email: String) async throws -> [[String: Any]] {
        var items: [[String: Any]] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            if let pageToken {
                components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "pageToken", value: pageToken)]
            }
            let json = try await accounts.getJSON(components.url!, as: email)
            items += json["items"] as? [[String: Any]] ?? []
            pageToken = json["nextPageToken"] as? String
        } while pageToken != nil
        return items
    }

    private func scheduleNextPoll() {
        timer?.invalidate()
        guard isRunning else { return }
        timer = Timer.scheduledTimer(withTimeInterval: schedule.interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh(force: true) }
        }
    }

    // MARK: - Snapshot

    private func isSelected(_ calendar: GoogleCalendarEntry) -> Bool {
        settings.isSelected(calendar.key, in: .google, default: calendar.isSelectedInGoogle)
    }

    private func rebuildSnapshot() {
        let order = accounts.accounts.map(\.email)
        let ordered = order.compactMap { results[$0] }
        let calendars = ordered.flatMap(\.calendars)
        let selectedKeys = Set(calendars.filter(isSelected).map(\.key))
        // Filter again so un-ticking a calendar hides it before the next fetch.
        let mapped = GoogleEventMapper.dedupe(ordered.flatMap(\.events))
            .filter { selectedKeys.contains($0.event.calendarIdentifier) }
        eventsByID = Dictionary(mapped.map { ($0.event.identifier, $0) }, uniquingKeysWith: { first, _ in first })

        let multipleAccounts = order.count > 1
        snapshot = EventSnapshot(
            calendars: calendars.map { entry in
                CalendarInfo(
                    id: entry.key,
                    // Same-named calendars ("Holidays") from two accounts need telling apart.
                    title: multipleAccounts && entry.title != entry.accountEmail
                        ? "\(entry.title) — \(entry.accountEmail)" : entry.title,
                    color: Color(hex: entry.colorHex) ?? .gray,
                    isSelectedByDefault: entry.isSelectedInGoogle
                )
            },
            events: mapped.map(\.event).sorted { $0.startDate < $1.startDate },
            accountEmails: order,
            status: currentStatus(noneSelected: !calendars.isEmpty && selectedKeys.isEmpty)
        )
    }

    private func currentStatus(noneSelected: Bool) -> SourceStatus {
        if accounts.accounts.isEmpty { return .notConnected }
        if !accounts.hasUsableAccount { return .needsReconnect }
        if results.isEmpty { return .loading }
        return noneSelected ? .nothingSelected : .ok
    }

    // MARK: - Decline

    /// Decline the exact occurrence through the account that owns it, then hide
    /// it right away; the next poll returns it as declined and the mapper drops it.
    func decline(eventID: String) async throws -> DeclineOutcome {
        guard let item = eventsByID[eventID], item.event.canDecline,
              let email = item.event.accountEmail else { return .notApplicable }
        guard try await accounts.declineInstance(calendarID: item.calendarID, eventID: item.eventID, as: email) else {
            return .notApplicable
        }
        for key in results.keys {
            results[key]?.events.removeAll { $0.event.identifier == eventID }
        }
        rebuildSnapshot()
        return .declined
    }

    // MARK: - Requests

    static let calendarListURL = URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!

    nonisolated static func window(now: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        (calendar.startOfDay(for: now), now.addingTimeInterval(7 * 24 * 3600))
    }

    nonisolated static func eventsURL(calendarID: String, window: (start: Date, end: Date)) -> URL {
        let escaped = calendarID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? calendarID
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/\(escaped)/events")!
        components.queryItems = [
            .init(name: "timeMin", value: GoogleEventMapper.rfc3339(window.start)),
            .init(name: "timeMax", value: GoogleEventMapper.rfc3339(window.end)),
            .init(name: "singleEvents", value: "true"),
            .init(name: "orderBy", value: "startTime"),
            .init(name: "showDeleted", value: "false"),
            .init(name: "maxResults", value: "250"),
        ]
        return components.url!
    }

    private static func isServerError(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == "GoogleCalendar" && ns.code >= 500
    }

    /// A 4xx about one calendar (not auth, not throttling) — skip that calendar
    /// instead of failing the whole account.
    private static func isPerCalendarError(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == "GoogleCalendar" && (400..<500).contains(ns.code)
            && !GoogleAccountStore.isAuthFailure(error) && !GoogleAccountStore.isRateLimited(error)
    }
}

extension Color {
    /// `#rrggbb` → Color; `nil` for anything else.
    init?(hex: String?) {
        guard let hex, hex.hasPrefix("#"), hex.count == 7,
              let value = Int(hex.dropFirst(), radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
