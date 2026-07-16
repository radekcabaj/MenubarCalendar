import Foundation

/// Extracts the best "join meeting" URL from an event. Pure and testable:
/// looks at the `url` field first, then scans `location` and `notes` for links,
/// preferring known conferencing hosts (Meet / Zoom / Teams / …).
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
