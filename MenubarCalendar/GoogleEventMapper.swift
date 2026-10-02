import Foundation

/// A calendar from `calendarList.list`, tagged with the account it came through.
struct GoogleCalendarEntry: Equatable {
    /// `"<account>/<calendar id>"` — unique across accounts; the selection id
    /// and `CalendarEvent.calendarIdentifier`.
    let key: String
    let accountEmail: String
    let calendarID: String
    let title: String
    /// `#rrggbb`, Google's `backgroundColor`.
    let colorHex: String?
    /// Owner / writer access — needed to send an RSVP through this calendar.
    let isWritable: Bool
    /// Ticked in Google Calendar's own sidebar: the default selection here
    /// until the user changes it in Settings.
    let isSelectedInGoogle: Bool
}

/// An event mapped from Google JSON, plus the ids needed to act on it.
struct MappedGoogleEvent: Equatable {
    let event: CalendarEvent
    let calendarID: String
    /// Per-occurrence id (the API is queried with `singleEvents=true`).
    let eventID: String
    /// The account whose token fetched it — every API call on it (decline)
    /// goes through this account. Not necessarily the owner: a calendar shared
    /// from another account is fetched through the account it's shared into,
    /// while `event.accountEmail` names the owner for Chrome-profile routing.
    let fetchedVia: String
    /// The account is listed as an attendee (`self == true`).
    let hasSelfAttendee: Bool
}

/// Pure JSON → model mapping for the Google Calendar API, kept free of
/// networking so it can be tested against literal API payloads.
enum GoogleEventMapper {
    static func calendarKey(accountEmail: String, calendarID: String) -> String {
        "\(accountEmail)/\(calendarID)"
    }

    static func calendar(from json: [String: Any], accountEmail: String) -> GoogleCalendarEntry? {
        guard let id = json["id"] as? String else { return nil }
        let role = json["accessRole"] as? String ?? ""
        let isPrimary = json["primary"] as? Bool ?? false
        return GoogleCalendarEntry(
            key: calendarKey(accountEmail: accountEmail, calendarID: id),
            accountEmail: accountEmail,
            calendarID: id,
            title: json["summaryOverride"] as? String ?? json["summary"] as? String ?? id,
            colorHex: json["backgroundColor"] as? String,
            isWritable: role == "owner" || role == "writer",
            // Google omits `selected` when false — except it can omit it on the
            // primary calendar too, which should never start hidden.
            isSelectedInGoogle: json["selected"] as? Bool ?? isPrimary
        )
    }

    /// `nil` for cancelled occurrences, events the account declined, and
    /// payloads without usable times.
    static func event(
        from json: [String: Any], calendar: GoogleCalendarEntry, timeZone: TimeZone = .current
    ) -> MappedGoogleEvent? {
        guard (json["status"] as? String) != "cancelled",
              let eventID = json["id"] as? String,
              let start = (json["start"] as? [String: Any]).flatMap({ time(from: $0, timeZone: timeZone) }),
              let end = (json["end"] as? [String: Any]).flatMap({ time(from: $0, timeZone: timeZone) })
        else { return nil }

        let attendees = json["attendees"] as? [[String: Any]] ?? []
        let me = attendees.first { ($0["self"] as? Bool) == true }
        if (me?["responseStatus"] as? String) == "declined" { return nil }

        let event = CalendarEvent(
            identifier: "\(calendar.key)/\(eventID)",
            title: json["summary"] as? String ?? "",
            startDate: start.date,
            endDate: end.date,
            isAllDay: start.isAllDay,
            calendarIdentifier: calendar.key,
            calendarTitle: calendar.title,
            url: meetingURL(from: json),
            location: json["location"] as? String,
            notes: json["description"] as? String,
            accountEmail: owner(selfAttendee: me, calendar: calendar),
            iCalUID: json["iCalUID"] as? String,
            webURL: (json["htmlLink"] as? String).flatMap(URL.init(string:)),
            isEditable: false,
            canDecline: calendar.isWritable && me != nil
        )
        return MappedGoogleEvent(
            event: event, calendarID: calendar.calendarID, eventID: eventID,
            fetchedVia: calendar.accountEmail, hasSelfAttendee: me != nil
        )
    }

    /// The account an event belongs to: the `self` attendee (the owner of the
    /// calendar it was read from), else the calendar's own address when it is
    /// a person's calendar, else the account that fetched it (group calendars,
    /// holidays…). A group calendar can itself be the `self` attendee; its
    /// address is no account, so it falls through.
    private static func owner(selfAttendee: [String: Any]?, calendar: GoogleCalendarEntry) -> String {
        if let email = selfAttendee?["email"] as? String, isPersonalAddress(email) { return email }
        if isPersonalAddress(calendar.calendarID) { return calendar.calendarID }
        return calendar.accountEmail
    }

    /// A person's own calendar is identified by their address; group,
    /// resource and imported calendars live under `*.calendar.google.com`.
    private static func isPersonalAddress(_ value: String) -> Bool {
        value.contains("@") && !value.lowercased().hasSuffix(".calendar.google.com")
    }

    /// The same meeting can arrive through two accounts (invited on both, or a
    /// calendar shared into both). Keep one copy per (iCalUID, start),
    /// preferring the copy fetched by the account that owns it, then one whose
    /// calendar is an attendee, else the first seen. Input order is account
    /// connection order. Events without a UID are all kept.
    static func dedupe(_ events: [MappedGoogleEvent]) -> [MappedGoogleEvent] {
        var indexByKey: [String: Int] = [:]
        var result: [MappedGoogleEvent] = []
        for item in events {
            guard let uid = item.event.iCalUID else {
                result.append(item)
                continue
            }
            let key = "\(uid)@\(item.event.startDate.timeIntervalSince1970)"
            if let index = indexByKey[key] {
                if rank(item) > rank(result[index]) {
                    result[index] = item
                }
            } else {
                indexByKey[key] = result.count
                result.append(item)
            }
        }
        return result
    }

    /// 2: read from a person's calendar by that person's own account; 1: read
    /// through a calendar that is an attendee; 0: otherwise. A group calendar
    /// doesn't count for 2 — its owner falls back to the fetching account,
    /// which says nothing about who owns the event.
    private static func rank(_ item: MappedGoogleEvent) -> Int {
        if isPersonalAddress(item.calendarID),
           item.event.accountEmail?.lowercased() == item.fetchedVia.lowercased() { return 2 }
        return item.hasSelfAttendee ? 1 : 0
    }

    /// RFC 3339 in UTC, for `timeMin` / `timeMax`.
    static func rfc3339(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    // MARK: - Private

    private static func meetingURL(from json: [String: Any]) -> URL? {
        if let link = json["hangoutLink"] as? String, let url = URL(string: link) {
            return url
        }
        let entryPoints = (json["conferenceData"] as? [String: Any])?["entryPoints"] as? [[String: Any]] ?? []
        guard let video = entryPoints.first(where: { ($0["entryPointType"] as? String) == "video" }),
              let uri = video["uri"] as? String else { return nil }
        return URL(string: uri)
    }

    /// Timed events carry `dateTime` (RFC 3339 with offset); all-day events
    /// carry `date` (`yyyy-MM-dd`, end exclusive), read as local midnight.
    private static func time(from field: [String: Any], timeZone: TimeZone) -> (date: Date, isAllDay: Bool)? {
        if let value = field["dateTime"] as? String {
            return parseDateTime(value).map { ($0, false) }
        }
        if let value = field["date"] as? String {
            return parseDay(value, timeZone: timeZone).map { ($0, true) }
        }
        return nil
    }

    private static func parseDateTime(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    private static func parseDay(_ value: String, timeZone: TimeZone) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
