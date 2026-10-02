import AppKit
import AuthenticationServices
import CryptoKit
import Foundation

/// The Google accounts the app is signed in to, and every Google Calendar REST
/// call made with them: reading calendars/events (the Google data source) and
/// sending a real "declined" RSVP with `sendUpdates=all` (both data sources —
/// EventKit has no public RSVP API).
///
/// Each account has its own OAuth tokens in the Keychain, so an event fetched
/// through an account knows which account owns it (Chrome-profile routing,
/// `authuser=`). An account whose token is revoked or lacks a scope is marked
/// `needsReconnect`; the others keep working.
///
/// No third-party SDKs (PRD §2): OAuth (PKCE), token refresh and the REST calls
/// are implemented on `URLSession` + `JSONSerialization`.
@MainActor
final class GoogleAccountStore: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    /// Connected accounts, in connection order (which also breaks ties when
    /// the same meeting is seen through two accounts).
    @Published private(set) var accounts: [GoogleAccount] = []
    /// Set while a sign-in is in flight, to disable the UI buttons.
    @Published private(set) var isBusy = false
    /// Last user-facing error (e.g. missing client id, failed decline).
    @Published var errorMessage: String?

    private let vault: TokenVault
    private let defaults: UserDefaults
    private var tokens: [String: GoogleTokens] = [:]

    private static let orderKey = "googleAccountOrder"
    /// Keychain account of the single item written before multi-account support.
    private static let legacyVaultAccount = "tokens"

    /// Whether the app was built with a Google client id configured.
    var isConfigured: Bool { GoogleConfig.clientID != nil }

    /// At least one account can make API calls right now.
    var hasUsableAccount: Bool { accounts.contains { !$0.needsReconnect } }

    init(vault: TokenVault = KeychainVault(), defaults: UserDefaults = .standard) {
        self.vault = vault
        self.defaults = defaults
        super.init()
        migrateLegacyTokens()
        let order = defaults.stringArray(forKey: Self.orderKey) ?? []
        for email in order {
            if let data = vault.load(account: email),
               let decoded = try? JSONDecoder().decode(GoogleTokens.self, from: data) {
                tokens[email] = decoded
            }
        }
        accounts = order.filter { tokens[$0] != nil }.map { GoogleAccount(email: $0) }
    }

    /// Move the pre-multi-account item to a per-email item, first in order. It
    /// was minted without `calendar.readonly`, so its first read 403s and marks
    /// it `needsReconnect` — Settings then asks for one reconnect.
    private func migrateLegacyTokens() {
        guard let data = vault.load(account: Self.legacyVaultAccount) else { return }
        vault.delete(account: Self.legacyVaultAccount)
        guard let legacy = try? JSONDecoder().decode(GoogleTokens.self, from: data),
              let email = legacy.email else { return } // no email to key it by: reconnect
        vault.save(data, account: email)
        var order = defaults.stringArray(forKey: Self.orderKey) ?? []
        order.removeAll { $0 == email }
        order.insert(email, at: 0)
        defaults.set(order, forKey: Self.orderKey)
    }

    // MARK: - Accounts

    /// Run the OAuth flow for a new account — or an existing one, which
    /// refreshes its tokens and clears `needsReconnect`. Safe to call from the UI.
    func addAccount() async {
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
            guard let email = try await fetchPrimaryEmail(accessToken: newTokens.accessToken) else {
                errorMessage = "Couldn't read the Google account's email address."
                return
            }
            newTokens.email = email
            store(newTokens, for: email)
        } catch {
            if let asError = error as? ASWebAuthenticationSessionError, asError.code == .canceledLogin {
                // User closed the sheet — not an error worth surfacing loudly.
                errorMessage = nil
            } else {
                errorMessage = "Google sign-in failed: \(error.localizedDescription)"
            }
        }
    }

    /// Persist tokens for `email`: append a new account, or refresh an existing
    /// one and clear its reconnect flag.
    func store(_ newTokens: GoogleTokens, for email: String) {
        guard let data = try? JSONEncoder().encode(newTokens) else { return }
        vault.save(data, account: email)
        tokens[email] = newTokens
        if let index = accounts.firstIndex(where: { $0.email == email }) {
            accounts[index].needsReconnect = false
        } else {
            accounts.append(GoogleAccount(email: email))
            defaults.set(accounts.map(\.email), forKey: Self.orderKey)
        }
    }

    func remove(email: String) {
        vault.delete(account: email)
        tokens[email] = nil
        accounts.removeAll { $0.email == email }
        defaults.set(accounts.map(\.email), forKey: Self.orderKey)
    }

    func markNeedsReconnect(email: String) {
        guard let index = accounts.firstIndex(where: { $0.email == email }),
              !accounts[index].needsReconnect else { return }
        accounts[index].needsReconnect = true
    }

    func recordSync(email: String, at date: Date = Date()) {
        guard let index = accounts.firstIndex(where: { $0.email == email }) else { return }
        accounts[index].lastSync = date
    }

    // MARK: - Error classification

    /// Google answers some rate limits with 403 (`rateLimitExceeded`,
    /// `userRateLimitExceeded`, `quotaExceeded`) — those must back off, not
    /// force a reconnect.
    static func isRateLimited(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == "GoogleCalendar" else { return false }
        if ns.code == 429 { return true }
        let body = ns.localizedDescription.lowercased()
        return ns.code == 403 && (body.contains("ratelimitexceeded") || body.contains("quotaexceeded"))
    }

    /// The token is revoked, expired or missing a scope: only signing in again helps.
    static func isAuthFailure(_ error: Error) -> Bool {
        if (error as? URLError)?.code == .userAuthenticationRequired { return true }
        let ns = error as NSError
        return ns.domain == "GoogleCalendar" && (ns.code == 401 || ns.code == 403) && !isRateLimited(error)
    }

    /// Surface a failed decline. The account was already marked for reconnect
    /// if the failure was about auth. Callers must NOT hide the event on these,
    /// or the user is left hidden-but-still-attending.
    func reportDeclineFailure(_ error: Error) {
        if Self.isAuthFailure(error) {
            errorMessage = "Google needs to be reconnected to decline events (its permissions changed). Open Settings and connect again."
        } else {
            errorMessage = "Couldn't send the decline to Google: \(error.localizedDescription)"
        }
    }

    // MARK: - Reading

    /// GET a Calendar API URL as `email`. An auth failure marks that account
    /// for reconnecting before rethrowing.
    func getJSON(_ url: URL, as email: String) async throws -> [String: Any] {
        try await markingAuthFailures(of: email) {
            let token = try await validAccessToken(for: email)
            return try await get(url: url, token: token)
        }
    }

    // MARK: - Declining

    /// Decline by iCal UID on whichever writable calendar of `email` has it
    /// (macOS Calendar source, where only the UID is known). Returns `false` if
    /// no writable copy was found or the account isn't an attendee.
    func declineEvent(iCalUID: String, as email: String) async throws -> Bool {
        try await markingAuthFailures(of: email) {
            let token = try await validAccessToken(for: email)
            for calendar in try await writableCalendars(token: token) {
                guard let event = try await findEvent(calendarID: calendar, iCalUID: iCalUID, token: token) else {
                    continue
                }
                return try await sendDecline(event, calendarID: calendar, token: token)
            }
            return false
        }
    }

    /// Decline one known occurrence (Google source, which has the exact ids).
    func declineInstance(calendarID: String, eventID: String, as email: String) async throws -> Bool {
        try await markingAuthFailures(of: email) {
            let token = try await validAccessToken(for: email)
            let event = try await get(url: eventURL(calendarID: calendarID, eventID: eventID), token: token)
            return try await sendDecline(event, calendarID: calendarID, token: token)
        }
    }

    /// Set the account's own attendee entry to declined, notifying everyone.
    /// `false` if the account isn't a listed attendee (e.g. organizer only).
    private func sendDecline(_ event: [String: Any], calendarID: String, token: String) async throws -> Bool {
        guard var attendees = event["attendees"] as? [[String: Any]],
              let selfIndex = attendees.firstIndex(where: { ($0["self"] as? Bool) == true }),
              let eventID = event["id"] as? String
        else { return false }
        attendees[selfIndex]["responseStatus"] = "declined"
        try await patch(calendarID: calendarID, eventID: eventID, body: ["attendees": attendees], token: token)
        return true
    }

    private func markingAuthFailures<T>(of email: String, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            if Self.isAuthFailure(error) { markNeedsReconnect(email: email) }
            throw error
        }
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
            // `select_account` so adding a second account doesn't silently
            // reuse the one already signed in to the browser session.
            .init(name: "prompt", value: "consent select_account"),
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

    /// A non-expired access token for `email`, refreshing if needed. A rejected
    /// refresh token (revoked / expired) marks the account `needsReconnect`;
    /// a network failure just throws, leaving the account as it is.
    private func validAccessToken(for email: String) async throws -> String {
        guard var current = tokens[email] else { throw URLError(.userAuthenticationRequired) }
        guard Date() >= current.expiry else { return current.accessToken }
        guard let clientID = GoogleConfig.clientID else { throw URLError(.userAuthenticationRequired) }

        let form: [String: String] = [
            "client_id": clientID,
            "refresh_token": current.refreshToken,
            "grant_type": "refresh_token",
        ]
        let json: [String: Any]
        do {
            json = try await postForm(url: "https://oauth2.googleapis.com/token", fields: form)
        } catch let error as NSError where error.domain == "GoogleCalendar" && (400..<500).contains(error.code) {
            markNeedsReconnect(email: email)
            throw URLError(.userAuthenticationRequired)
        }
        guard let access = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? Double else {
            markNeedsReconnect(email: email)
            throw URLError(.userAuthenticationRequired)
        }
        current.accessToken = access
        current.expiry = Date().addingTimeInterval(expiresIn - 60)
        // Google may or may not return a new refresh token; keep the old if not.
        if let newRefresh = json["refresh_token"] as? String {
            current.refreshToken = newRefresh
        }
        if let data = try? JSONEncoder().encode(current) {
            vault.save(data, account: email)
        }
        tokens[email] = current
        return access
    }

    // MARK: - REST helpers

    /// Calendar ids the account can write to (owner / writer access).
    private func writableCalendars(token: String) async throws -> [String] {
        let json = try await get(
            url: URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!,
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
        let json = try await get(url: components.url!, token: token)
        let items = json["items"] as? [[String: Any]] ?? []
        return items.first
    }

    private func eventURL(calendarID: String, eventID: String) -> URL {
        URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(pathEscaped(calendarID))/events/\(pathEscaped(eventID))")!
    }

    private func patch(calendarID: String, eventID: String, body: [String: Any], token: String) async throws {
        var components = URLComponents(url: eventURL(calendarID: calendarID, eventID: eventID),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "sendUpdates", value: "all")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await send(request)
    }

    private func fetchPrimaryEmail(accessToken: String) async throws -> String? {
        let json = try await get(
            url: URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!,
            token: accessToken
        )
        let items = json["items"] as? [[String: Any]] ?? []
        let primary = items.first(where: { ($0["primary"] as? Bool) == true })
        return primary?["id"] as? String
    }

    // MARK: - URLSession plumbing

    private func get(url: URL, token: String) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
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

/// One connected Google account as shown in Settings.
struct GoogleAccount: Identifiable, Equatable {
    var id: String { email }
    let email: String
    /// Token revoked / expired or missing a scope: the user must sign in again.
    var needsReconnect = false
    /// When this account's events were last fetched successfully.
    var lastSync: Date?
}

/// OAuth tokens persisted in the Keychain, one item per account.
struct GoogleTokens: Codable {
    var accessToken: String
    var refreshToken: String
    /// When the access token should be treated as expired (already padded).
    var expiry: Date
    var email: String?
}

/// Where per-account token blobs live: the Keychain in the app, memory in tests.
protocol TokenVault {
    func save(_ data: Data, account: String)
    func load(account: String) -> Data?
    func delete(account: String)
}

/// Generic-password Keychain items under one service, keyed by account email.
struct KeychainVault: TokenVault {
    private let service = "com.rc.MenubarCalendar.google"

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func save(_ data: Data, account: String) {
        SecItemDelete(query(account) as CFDictionary)
        var attributes = query(account)
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func load(account: String) -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

/// Reads the Google client id from Info.plist and derives the reversed-client-id
/// redirect used by Google's installed-app OAuth flow.
private enum GoogleConfig {
    // `calendar.events` reads/patches the RSVP; `calendar.calendarlist.readonly`
    // lists calendars (finding where an invitation lives, the account email);
    // `calendar.readonly` reads every selected calendar for the Google source.
    static let scope = "https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/calendar.calendarlist.readonly https://www.googleapis.com/auth/calendar.readonly"

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
