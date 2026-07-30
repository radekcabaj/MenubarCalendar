import AppKit
import AuthenticationServices
import CryptoKit
import Foundation

/// Google Calendar integration used *only* for the "Decline" swipe action.
///
/// EventKit has no public RSVP API, so declining an invitation through the
/// shared calendar store can't notify the organizer. This service talks to the
/// Google Calendar REST API directly to set the user's attendee
/// `responseStatus` to `declined` with `sendUpdates=all`, which makes Google
/// email the organizer — the same result as declining in Calendar.app.
///
/// It authenticates one Google account (e.g. mail@radekcabaj.com). Because that
/// account can also see calendars shared into it with "Make changes to events"
/// access, a single connection can decline events on those shared calendars too
/// (e.g. radek@tonik.com) — Google records the decline server-side.
///
/// No third-party SDKs (PRD §2): OAuth (PKCE), token refresh and the REST calls
/// are implemented on `URLSession` + `JSONSerialization`.
@MainActor
final class GoogleCalendarService: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    /// Whether a Google account is currently connected.
    @Published private(set) var isConnected: Bool = false
    /// The connected account's primary-calendar id (its email), for display.
    @Published private(set) var accountEmail: String?
    /// Set while a connect/refresh is in flight, to disable the UI button.
    @Published private(set) var isBusy: Bool = false
    /// Last user-facing error (e.g. missing client id, auth cancelled).
    @Published var errorMessage: String?

    private var tokens: GoogleTokens? {
        didSet {
            isConnected = tokens != nil
            accountEmail = tokens?.email
        }
    }

    /// Whether the app was built with a Google client id configured.
    var isConfigured: Bool { GoogleConfig.clientID != nil }

    override init() {
        super.init()
        tokens = GoogleKeychain.load()
        isConnected = tokens != nil
        accountEmail = tokens?.email
    }

    // MARK: - Connect / disconnect

    /// Run the OAuth flow and persist tokens. Safe to call from the UI.
    func connect() async {
        guard let clientID = GoogleConfig.clientID else {
            errorMessage = "No Google client ID configured (see setup notes)."
            return
        }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let verifier = Self.randomCodeVerifier()
            let challenge = Self.codeChallenge(for: verifier)
            let code = try await authorize(clientID: clientID, challenge: challenge)
            var newTokens = try await exchange(code: code, verifier: verifier, clientID: clientID)
            newTokens.email = try? await fetchPrimaryEmail(accessToken: newTokens.accessToken)
            GoogleKeychain.save(newTokens)
            tokens = newTokens
        } catch {
            if let asError = error as? ASWebAuthenticationSessionError, asError.code == .canceledLogin {
                // User closed the sheet — not an error worth surfacing loudly.
                errorMessage = nil
            } else {
                errorMessage = "Google sign-in failed: \(error.localizedDescription)"
            }
        }
    }

    func disconnect() {
        GoogleKeychain.delete()
        tokens = nil
    }

    /// Handle a decline that failed at the Google API. An auth/scope failure
    /// means the stored token is stale (e.g. minted before a required scope was
    /// added), so we drop it — the account shows disconnected and reconnecting
    /// mints a token with the current scopes. Other failures just surface a
    /// message. Callers must NOT locally delete the event on these, or the user
    /// is left hidden-but-still-attending.
    func reportDeclineFailure(_ error: Error) {
        let ns = error as NSError
        let isAuthFailure = ns.domain == "GoogleCalendar" && (ns.code == 401 || ns.code == 403)
        if isAuthFailure {
            disconnect()
            errorMessage = "Google needs to be reconnected to decline events (its permissions changed). Open Settings and connect again."
        } else {
            errorMessage = "Couldn't send the decline to Google: \(error.localizedDescription)"
        }
    }

    // MARK: - Public API: decline

    /// Decline the event with the given iCal UID on whichever writable calendar
    /// (owned or shared with edit access) it lives on. Returns `true` if a decline
    /// was sent, `false` if the event wasn't found on a writable calendar or the
    /// user isn't an attendee (caller should then fall back to a local remove).
    func declineEvent(iCalUID: String) async throws -> Bool {
        let token = try await validAccessToken()
        for calendar in try await writableCalendars(token: token) {
            guard var event = try await findEvent(calendarID: calendar, iCalUID: iCalUID, token: token) else {
                continue
            }
            guard var attendees = event["attendees"] as? [[String: Any]],
                  let selfIndex = attendees.firstIndex(where: { ($0["self"] as? Bool) == true }),
                  let eventID = event["id"] as? String
            else {
                // Found the event but we're not a listed attendee (e.g. we're the
                // organizer with no attendee entry) — nothing to RSVP.
                return false
            }
            attendees[selfIndex]["responseStatus"] = "declined"
            event["attendees"] = attendees
            try await patch(
                calendarID: calendar, eventID: eventID,
                body: ["attendees": attendees], token: token
            )
            return true
        }
        return false
    }

    // MARK: - OAuth

    private func authorize(clientID: String, challenge: String) async throws -> String {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: GoogleConfig.redirectURI(clientID: clientID)),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: GoogleConfig.scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        let authURL = components.url!
        let scheme = GoogleConfig.redirectScheme(clientID: clientID)

        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: scheme) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: error ?? URLError(.badServerResponse))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            if !session.start() {
                continuation.resume(throwing: URLError(.cannotConnectToHost))
            }
        }

        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            throw URLError(.userAuthenticationRequired)
        }
        return code
    }

    private func exchange(code: String, verifier: String, clientID: String) async throws -> GoogleTokens {
        let form: [String: String] = [
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": GoogleConfig.redirectURI(clientID: clientID),
        ]
        let json = try await postForm(url: "https://oauth2.googleapis.com/token", fields: form)
        guard let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String,
              let expiresIn = json["expires_in"] as? Double else {
            throw URLError(.cannotParseResponse)
        }
        return GoogleTokens(
            accessToken: access,
            refreshToken: refresh,
            expiry: Date().addingTimeInterval(expiresIn - 60),
            email: nil
        )
    }

    /// A non-expired access token, refreshing if needed.
    private func validAccessToken() async throws -> String {
        guard var current = tokens else { throw URLError(.userAuthenticationRequired) }
        guard Date() >= current.expiry else { return current.accessToken }
        guard let clientID = GoogleConfig.clientID else { throw URLError(.userAuthenticationRequired) }

        let form: [String: String] = [
            "client_id": clientID,
            "refresh_token": current.refreshToken,
            "grant_type": "refresh_token",
        ]
        let json = try await postForm(url: "https://oauth2.googleapis.com/token", fields: form)
        guard let access = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? Double else {
            // Refresh token revoked / expired → force reconnect.
            disconnect()
            throw URLError(.userAuthenticationRequired)
        }
        current.accessToken = access
        current.expiry = Date().addingTimeInterval(expiresIn - 60)
        // Google may or may not return a new refresh token; keep the old if not.
        if let newRefresh = json["refresh_token"] as? String {
            current.refreshToken = newRefresh
        }
        GoogleKeychain.save(current)
        tokens = current
        return access
    }

    // MARK: - REST helpers

    /// Calendar ids the account can write to (owner / writer access).
    private func writableCalendars(token: String) async throws -> [String] {
        let json = try await get(
            url: "https://www.googleapis.com/calendar/v3/users/me/calendarList",
            token: token
        )
        let items = json["items"] as? [[String: Any]] ?? []
        // Primary first so the common case (own invitation) resolves fastest.
        let writable = items.filter { ["owner", "writer"].contains($0["accessRole"] as? String ?? "") }
        return writable
            .sorted { (($0["primary"] as? Bool) == true ? 0 : 1) < (($1["primary"] as? Bool) == true ? 0 : 1) }
            .compactMap { $0["id"] as? String }
    }

    private func findEvent(calendarID: String, iCalUID: String, token: String) async throws -> [String: Any]? {
        var components = URLComponents(string:
            "https://www.googleapis.com/calendar/v3/calendars/\(pathEscaped(calendarID))/events")!
        components.queryItems = [
            .init(name: "iCalUID", value: iCalUID),
            .init(name: "showDeleted", value: "false"),
            .init(name: "maxResults", value: "5"),
        ]
        let json = try await get(url: components.url!.absoluteString, token: token)
        let items = json["items"] as? [[String: Any]] ?? []
        return items.first
    }

    private func patch(calendarID: String, eventID: String, body: [String: Any], token: String) async throws {
        let urlString = "https://www.googleapis.com/calendar/v3/calendars/\(pathEscaped(calendarID))/events/\(pathEscaped(eventID))?sendUpdates=all"
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await send(request)
    }

    private func fetchPrimaryEmail(accessToken: String) async throws -> String? {
        let json = try await get(
            url: "https://www.googleapis.com/calendar/v3/users/me/calendarList",
            token: accessToken
        )
        let items = json["items"] as? [[String: Any]] ?? []
        let primary = items.first(where: { ($0["primary"] as? Bool) == true })
        return primary?["id"] as? String
    }

    // MARK: - URLSession plumbing

    private func get(url: String, token: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await send(request)
    }

    private func postForm(url: String, fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = fields
            .map { "\(formEscaped($0.key))=\(formEscaped($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)
        return try await send(request)
    }

    @discardableResult
    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "GoogleCalendar", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
        if data.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: - Encoding helpers

    private func pathEscaped(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    private func formEscaped(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: - PKCE

    private static func randomCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}

/// OAuth tokens persisted in the Keychain.
private struct GoogleTokens: Codable {
    var accessToken: String
    var refreshToken: String
    /// When the access token should be treated as expired (already padded).
    var expiry: Date
    var email: String?
}

/// Reads the Google client id from Info.plist and derives the reversed-client-id
/// redirect used by Google's installed-app OAuth flow.
private enum GoogleConfig {
    // `calendar.events` lets us read/patch the RSVP; `calendar.calendarlist.readonly`
    // is required for `calendarList.list`, which we use to find the writable
    // calendar an invitation lives on (and to resolve the account email).
    // Without the second scope every decline 403s on the first API call.
    static let scope = "https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/calendar.calendarlist.readonly"

    static var clientID: String? {
        let value = Bundle.main.object(forInfoDictionaryKey: "GoogleOAuthClientID") as? String
        guard let value, !value.isEmpty, !value.hasPrefix("YOUR_") else { return nil }
        return value
    }

    /// `NNNN-xxxx.apps.googleusercontent.com` → `com.googleusercontent.apps.NNNN-xxxx`.
    static func redirectScheme(clientID: String) -> String {
        let suffix = ".apps.googleusercontent.com"
        let core = clientID.hasSuffix(suffix) ? String(clientID.dropLast(suffix.count)) : clientID
        return "com.googleusercontent.apps.\(core)"
    }

    static func redirectURI(clientID: String) -> String {
        "\(redirectScheme(clientID: clientID)):/oauth2redirect"
    }
}

/// Minimal Keychain wrapper storing the token blob as one generic-password item.
private enum GoogleKeychain {
    private static let service = "com.rc.MenubarCalendar.google"
    private static let account = "tokens"

    static func save(_ tokens: GoogleTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func load() -> GoogleTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(GoogleTokens.self, from: data)
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
