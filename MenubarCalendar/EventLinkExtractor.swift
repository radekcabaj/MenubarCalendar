import Foundation

/// Extracts the best "join meeting" URL from an event. Pure and testable:
/// looks at the `url` field first, then scans `location` and `notes` for links,
/// preferring known conferencing hosts (Meet / Zoom / Teams / …). Also pins
/// Google links to the event's own account via `accountURL(_:authuserEmail:)`.
enum EventLinkExtractor {
    /// Hosts we treat as video-conferencing links (matched as host or subdomain).
    static let meetingHosts = [
        "meet.google.com",
        "zoom.us",
        "teams.microsoft.com",
        "teams.live.com",
        "webex.com",
        "whereby.com",
        "meet.jit.si",
        "around.co",
        "chime.aws",
        "bluejeans.com",
        "gotomeeting.com",
    ]

    static func meetingURL(for event: CalendarEvent) -> URL? {
        // 1. Explicit URL field, if it's a web link.
        if let url = event.url, isWeb(url) {
            return url
        }
        // 2. Scan location + notes.
        let text = [event.location, event.notes]
            .compactMap { $0 }
            .joined(separator: "\n")
        let urls = detectURLs(in: text)
        // Prefer a known meeting host; otherwise the first web link found.
        return urls.first(where: isMeetingHost) ?? urls.first
    }

    /// Add/replace `authuser=<email>` on Google links (`*.google.com`, so Meet
    /// and Calendar included) so the event's own account is used when the
    /// browser is signed into several. Non-Google URLs are returned as-is.
    static func accountURL(_ url: URL, authuserEmail: String) -> URL {
        guard let host = url.host?.lowercased(),
              host == "google.com" || host.hasSuffix(".google.com"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        var items = (components.queryItems ?? []).filter { $0.name != "authuser" }
        items.append(URLQueryItem(name: "authuser", value: authuserEmail))
        components.queryItems = items
        return components.url ?? url
    }

    static func isWeb(_ url: URL) -> Bool {
        url.scheme == "http" || url.scheme == "https"
    }

    static func isMeetingHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return meetingHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func detectURLs(in text: String) -> [URL] {
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range)
            .compactMap { $0.url }
            .filter(isWeb)
    }
}
