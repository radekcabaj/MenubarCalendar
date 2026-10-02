import XCTest
@testable import MenubarCalendar

/// Token storage double, so tests never touch the real Keychain.
final class InMemoryVault: TokenVault {
    var items: [String: Data] = [:]
    func save(_ data: Data, account: String) { items[account] = data }
    func load(account: String) -> Data? { items[account] }
    func delete(account: String) { items[account] = nil }
}

@MainActor
final class GoogleAccountStoreTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "GoogleAccountStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func tokens(_ email: String?) -> GoogleTokens {
        GoogleTokens(accessToken: "access", refreshToken: "refresh", expiry: .distantFuture, email: email)
    }

    private func encoded(_ tokens: GoogleTokens) -> Data {
        try! JSONEncoder().encode(tokens)
    }

    func testMigratesTheLegacySingleAccountItem() {
        let vault = InMemoryVault()
        vault.items["tokens"] = encoded(tokens("mail@radekcabaj.com"))
        let defaults = makeDefaults()

        let store = GoogleAccountStore(vault: vault, defaults: defaults)

        XCTAssertEqual(store.accounts.map(\.email), ["mail@radekcabaj.com"])
        XCTAssertNil(vault.items["tokens"])
        XCTAssertNotNil(vault.items["mail@radekcabaj.com"])
        XCTAssertEqual(defaults.stringArray(forKey: "googleAccountOrder"), ["mail@radekcabaj.com"])
        XCTAssertTrue(store.hasUsableAccount)
    }

    func testLegacyItemWithoutEmailIsDropped() {
        let vault = InMemoryVault()
        vault.items["tokens"] = encoded(tokens(nil))
        let store = GoogleAccountStore(vault: vault, defaults: makeDefaults())
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertTrue(vault.items.isEmpty)
    }

    func testAccountsLoadInStoredOrderAndSkipMissingTokens() {
        let vault = InMemoryVault()
        vault.items["b@x.com"] = encoded(tokens("b@x.com"))
        vault.items["a@x.com"] = encoded(tokens("a@x.com"))
        let defaults = makeDefaults()
        defaults.set(["b@x.com", "gone@x.com", "a@x.com"], forKey: "googleAccountOrder")

        let store = GoogleAccountStore(vault: vault, defaults: defaults)
        XCTAssertEqual(store.accounts.map(\.email), ["b@x.com", "a@x.com"])
    }

    func testStoreAppendsNewAccountsAndClearsReconnectOnExisting() {
        let defaults = makeDefaults()
        let store = GoogleAccountStore(vault: InMemoryVault(), defaults: defaults)
        store.store(tokens("a@x.com"), for: "a@x.com")
        store.store(tokens("b@x.com"), for: "b@x.com")
        store.markNeedsReconnect(email: "a@x.com")
        XCTAssertTrue(store.accounts[0].needsReconnect)

        store.store(tokens("a@x.com"), for: "a@x.com")

        XCTAssertEqual(store.accounts.map(\.email), ["a@x.com", "b@x.com"])
        XCTAssertFalse(store.accounts[0].needsReconnect)
        XCTAssertEqual(defaults.stringArray(forKey: "googleAccountOrder"), ["a@x.com", "b@x.com"])
    }

    func testRemoveDeletesTokensAndOrder() {
        let vault = InMemoryVault()
        let defaults = makeDefaults()
        let store = GoogleAccountStore(vault: vault, defaults: defaults)
        store.store(tokens("a@x.com"), for: "a@x.com")
        store.store(tokens("b@x.com"), for: "b@x.com")

        store.remove(email: "a@x.com")

        XCTAssertEqual(store.accounts.map(\.email), ["b@x.com"])
        XCTAssertNil(vault.items["a@x.com"])
        XCTAssertEqual(defaults.stringArray(forKey: "googleAccountOrder"), ["b@x.com"])
    }

    func testHasUsableAccountIgnoresAccountsNeedingReconnect() {
        let store = GoogleAccountStore(vault: InMemoryVault(), defaults: makeDefaults())
        XCTAssertFalse(store.hasUsableAccount)
        store.store(tokens("a@x.com"), for: "a@x.com")
        store.markNeedsReconnect(email: "a@x.com")
        XCTAssertFalse(store.hasUsableAccount)
    }

    func testRecordSync() {
        let store = GoogleAccountStore(vault: InMemoryVault(), defaults: makeDefaults())
        store.store(tokens("a@x.com"), for: "a@x.com")
        let when = Date(timeIntervalSince1970: 1_000)
        store.recordSync(email: "a@x.com", at: when)
        XCTAssertEqual(store.accounts[0].lastSync, when)
    }

    // MARK: Error classification

    private func httpError(_ code: Int, _ body: String = "") -> NSError {
        NSError(domain: "GoogleCalendar", code: code, userInfo: [NSLocalizedDescriptionKey: body])
    }

    func testUnauthorizedIsAuthFailure() {
        XCTAssertTrue(GoogleAccountStore.isAuthFailure(httpError(401)))
        XCTAssertTrue(GoogleAccountStore.isAuthFailure(httpError(403, #"{"error":{"errors":[{"reason":"insufficientPermissions"}]}}"#)))
        XCTAssertTrue(GoogleAccountStore.isAuthFailure(URLError(.userAuthenticationRequired)))
    }

    // Review Focus 2: Google rate-limits with 403 too; that must back off, not reconnect.
    func testRateLimited403IsNotAnAuthFailure() {
        let error = httpError(403, #"{"error":{"errors":[{"domain":"usageLimits","reason":"rateLimitExceeded"}]}}"#)
        XCTAssertTrue(GoogleAccountStore.isRateLimited(error))
        XCTAssertFalse(GoogleAccountStore.isAuthFailure(error))
        XCTAssertTrue(GoogleAccountStore.isRateLimited(httpError(403, "userRateLimitExceeded")))
        XCTAssertTrue(GoogleAccountStore.isRateLimited(httpError(429)))
    }

    func testNetworkErrorsAreNeither() {
        let offline = URLError(.notConnectedToInternet)
        XCTAssertFalse(GoogleAccountStore.isAuthFailure(offline))
        XCTAssertFalse(GoogleAccountStore.isRateLimited(offline))
        XCTAssertFalse(GoogleAccountStore.isAuthFailure(httpError(500)))
    }
}
